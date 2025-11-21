defmodule Membrane.RTP.AV1.Rav1Depayloader.Reorder do
  @moduledoc """
  Helpers for bounded packet reordering/reassembly per RTP timestamp.

  Usage: keep `state.reorder` as a map from rtp_timestamp -> ReorderContext.
  Call `Reorder.insert_packet(state, pkt)` on each incoming packet; it returns
  `{state, maybe_completed_au}` where `maybe_completed_au` is `{:ok, au_packets, pts}` when an AU
  finished (marker or forced), or `:pending`.
  """

  require Membrane.Logger
  @seq_mod 65_536
  @default_timeout_ms 500

  defstruct packets: %{},
            # seq -> {header_info, obu_payload, full_header}
            min_seq: nil,
            # smallest seq observed (wrap-aware)
            max_seq: nil,
            # largest seq observed (wrap-aware)
            first_seen_at: nil,
            marker_seen: false,
            pts: nil

  @type t :: %__MODULE__{
          packets: %{optional(non_neg_integer) => any()},
          min_seq: non_neg_integer | nil,
          max_seq: non_neg_integer | nil,
          first_seen_at: integer() | nil,
          marker_seen: boolean(),
          pts: any()
        }

  # Compute distance from a to b in sequence space (0..65535), small positive result if b is after a
  def seq_distance(a, b) when is_integer(a) and is_integer(b) do
    if a <= b, do: b - a, else: @seq_mod - a + b
  end

  # Insert a packet into reorder map (per timestamp).
  # pkt must be a map with :seq, :payload, :marker, :pts, :ts fields.
  # opts: %{max_reorder_buffer:, max_seq_gap:}
  def insert_packet(state, %{seq: seq, payload: payload, marker: marker, pts: pts, ts: ts}, opts) do
    reorder = Map.get(state.reorder || %{}, ts, %__MODULE__{})
    now = System.monotonic_time(:millisecond)

    reorder =
      reorder
      |> ensure_meta(now, pts)
      |> put_packet(seq, payload, marker)

    reorder_count = map_size(reorder.packets)
    max_buf = opts[:max_reorder_buffer] || 10
    max_gap = opts[:max_seq_gap] || 5

    # store back
    state = put_in(state.reorder[ts], reorder)

    # If marker seen for this timestamp -> attempt to flush (complete AU)
    cond do
      reorder.marker_seen ->
        # Try to assemble in-order up to highest contiguous seq (respecting gaps and max_gap)
        case try_assemble(reorder, max_gap) do
          {:ok, au_packets, _new_reorder} ->
            # remove context
            state = Map.update!(state, :reorder, fn m -> Map.delete(m, ts) end)
            {state, {:ok, au_packets, pts}}

          :need_more ->
            # Keep waiting for missing packets
            {state, :pending}
        end

      # If buffer is full -> force progress: attempt to assemble even with gaps (skip missing)
      reorder_count >= max_buf ->
        {:ok, au_packets, _new_reorder} = force_assemble(reorder, max_gap)
        state = Map.update!(state, :reorder, fn m -> Map.delete(m, ts) end)
        {state, {:ok, au_packets, pts}}

      true ->
        {state, :pending}
    end
  end

  # Mark initial meta
  defp ensure_meta(%__MODULE__{first_seen_at: nil} = r, now, pts) do
    %__MODULE__{r | first_seen_at: now, pts: pts}
  end

  defp ensure_meta(r, _now, _pts), do: r

  # Put packet (ignore duplicates)
  defp put_packet(%__MODULE__{packets: pkts, min_seq: nil, max_seq: nil} = r, seq, payload, marker) do
    pkts2 = Map.put_new(pkts, seq, payload)

    %__MODULE__{
      r
      | packets: pkts2,
        min_seq: seq,
        max_seq: seq,
        marker_seen: marker || r.marker_seen
    }
  end

  defp put_packet(%__MODULE__{packets: pkts, min_seq: min, max_seq: max} = r, seq, payload, marker) do
    if Map.has_key?(pkts, seq) do
      %__MODULE__{r | marker_seen: marker || r.marker_seen}
    else
      pkts2 = Map.put(pkts, seq, payload)
      # Keep raw sequence numbers, just track min/max
      min2 = if seq_cmp(seq, min), do: seq, else: min
      max2 = if seq_cmp(max, seq), do: seq, else: max

      %__MODULE__{
        r
        | packets: pkts2,
          min_seq: min2,
          max_seq: max2,
          marker_seen: marker || r.marker_seen
      }
    end
  end

  # Attempt a conservative assemble: require contiguous runs from min_seq up to highest present
  # and fail if gaps > max_gap
  defp try_assemble(%__MODULE__{packets: pkts, min_seq: min_seq} = r, max_gap) do
    if is_nil(min_seq) or map_size(pkts) == 0 do
      :need_more
    else
      ordered_seqs = pkts |> Map.keys() |> Enum.sort(&seq_cmp/2)
      # Build contiguous run starting from the lowest seq observed
      {contig_seqs, _gap_found?} = build_contig_run(ordered_seqs, max_gap)

      if contig_seqs == [] do
        :need_more
      else
        # assemble packets in contig order
        au_packets = Enum.map(contig_seqs, &pkts[&1])
        {:ok, au_packets, r}
      end
    end
  end

  defp build_contig_run([], _max_gap), do: {[], false}

  defp build_contig_run([first | rest], max_gap) do
    contig = [first]

    Enum.reduce_while(rest, {contig, false}, fn seq, {acc, _} ->
      prev = List.last(acc)
      gap = seq_distance(prev, seq)

      cond do
        gap == 0 ->
          # Duplicate, skip
          {:cont, {acc, false}}

        gap == 1 ->
          # Contiguous, add it
          {:cont, {acc ++ [seq], false}}

        gap <= max_gap ->
          # Small gap => we cannot include until missing arrives
          {:halt, {acc, true}}

        true ->
          # Large gap => stop
          {:halt, {acc, true}}
      end
    end)
  end

  # Force assemble: process what we have, skipping missing sequences up to max_gap.
  # This is used when buffer is full (max_reorder_buffer reached).
  defp force_assemble(%__MODULE__{packets: pkts} = r, _max_gap) do
    # Sort seqs (wrap-aware)
    ordered = pkts |> Map.keys() |> Enum.sort(&seq_cmp/2)
    # We will stitch present packets in order; gaps are skipped.
    au_packets = Enum.map(ordered, &pkts[&1])
    {:ok, au_packets, r}
  end

  # Sequence comparison that handles wrapping: prefer smaller forward distance
  defp seq_cmp(a, b) do
    seq_distance(a, b) <= seq_distance(b, a)
  end

  # Periodic cleanup: drop contexts older than timeout_ms, emit discontinuities if needed
  def cleanup_old(state, opts) do
    timeout = opts[:reorder_timeout_ms] || @default_timeout_ms
    now = System.monotonic_time(:millisecond)

    {to_drop, keep} =
      (state.reorder || %{})
      |> Enum.split_with(fn {_ts, ctx} -> now - ctx.first_seen_at > timeout end)

    new_state = %{state | reorder: Map.new(keep)}
    dropped_ts = Enum.map(to_drop, fn {ts, _} -> ts end)
    {new_state, dropped_ts}
  end
end
