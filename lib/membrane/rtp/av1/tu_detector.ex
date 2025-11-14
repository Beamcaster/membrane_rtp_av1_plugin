defmodule Membrane.RTP.AV1.TUDetector do
  @moduledoc """
  Temporal Unit (TU) boundary detection for AV1 access units.

  Per AV1 specification, a Temporal Unit consists of:
  - Optional OBU_SEQUENCE_HEADER
  - Optional OBU_TEMPORAL_DELIMITER
  - One or more frame OBUs (OBU_FRAME_HEADER + OBU_TILE_GROUP, or OBU_FRAME)
  - Optional metadata and padding

  This module analyzes an access unit and splits it into one or more TUs,
  enabling proper RTP marker bit placement at true TU boundaries.
  """

  alias Membrane.RTP.AV1.{OBU, OBUHeader}

  @type temporal_unit :: %{
          obus: [binary()],
          is_tu_end: boolean(),
          frame_count: non_neg_integer()
        }

  @doc """
  Splits an access unit into temporal units and marks TU boundaries.

  Returns a list of TU structs, where each TU contains:
  - obus: List of OBU binaries in this TU
  - is_tu_end: Whether this TU marks the end of a temporal unit
  - frame_count: Number of frames in this TU

  ## Examples

      iex> au = <<...>>  # Single frame access unit
      iex> [tu] = TUDetector.detect_tu_boundaries(au)
      iex> tu.is_tu_end
      true
  """
  @spec detect_tu_boundaries(binary()) :: [temporal_unit()]
  def detect_tu_boundaries(access_unit) when is_binary(access_unit) do
    obus = OBU.split_obus(access_unit)
    analyze_obus(obus)
  end

  @doc """
  Determines if a packet list should have marker bit set.

  For single TU: marker on last packet
  For multiple TUs: marker on last packet of each TU

  Returns a list of {packet_payload, marker_bit} tuples.
  """
  @spec assign_markers([binary()], [temporal_unit()]) :: [{binary(), boolean()}]
  def assign_markers(packets, tus) when is_list(packets) and is_list(tus) do
    # Simple case: single TU means marker on last packet
    if length(tus) == 1 do
      packets
      |> Enum.with_index(1)
      |> Enum.map(fn {pkt, idx} -> {pkt, idx == length(packets)} end)
    else
      # Complex case: need to map packets to TU boundaries
      # For now, use simple heuristic: mark last packet only
      # TODO: Implement proper packet-to-TU mapping
      packets
      |> Enum.with_index(1)
      |> Enum.map(fn {pkt, idx} -> {pkt, idx == length(packets)} end)
    end
  end

  # Private functions

  defp analyze_obus(obus) do
    obus
    |> Enum.reduce({[], nil, 0}, &process_obu/2)
    |> finalize_tus()
  end

  defp process_obu(obu, {tus, current_tu, frame_count}) do
    case parse_obu_type(obu) do
      {:ok, type} ->
        cond do
          # Temporal delimiter or sequence header starts a new TU
          type in [:temporal_delimiter, :sequence_header] ->
            new_tus = finalize_current_tu(tus, current_tu, frame_count)
            new_tu = %{obus: [obu], is_tu_end: false, frame_count: 0}
            {new_tus, new_tu, 0}

          # Frame-related OBUs
          type in [:frame_header, :frame, :tile_group] ->
            updated_tu = add_obu_to_current(current_tu, obu)

            new_frame_count =
              if type in [:frame, :frame_header], do: frame_count + 1, else: frame_count

            {tus, updated_tu, new_frame_count}

          # Metadata and padding - add to current TU
          true ->
            updated_tu = add_obu_to_current(current_tu, obu)
            {tus, updated_tu, frame_count}
        end

      {:error, _reason} ->
        # Unparseable OBU - add to current TU
        updated_tu = add_obu_to_current(current_tu, obu)
        {tus, updated_tu, frame_count}
    end
  end

  defp parse_obu_type(obu) do
    with {:ok, {_len, _leb_bytes, payload}} <- OBU.leb128_decode_prefix(obu),
         {:ok, header, _rest} <- OBUHeader.parse(payload) do
      {:ok, header.obu_type}
    else
      _ -> {:error, :parse_failed}
    end
  end

  defp add_obu_to_current(nil, obu) do
    %{obus: [obu], is_tu_end: false, frame_count: 0}
  end

  defp add_obu_to_current(tu, obu) do
    %{tu | obus: tu.obus ++ [obu]}
  end

  defp finalize_current_tu(tus, nil, _frame_count), do: tus

  defp finalize_current_tu(tus, tu, frame_count) do
    # A TU ends when we have at least one frame
    tu_with_end = %{tu | is_tu_end: frame_count > 0, frame_count: frame_count}
    tus ++ [tu_with_end]
  end

  defp finalize_tus({tus, current_tu, frame_count}) do
    final_tus = finalize_current_tu(tus, current_tu, frame_count)

    # Ensure at least one TU exists and the last one is marked as end
    case final_tus do
      [] ->
        [%{obus: [], is_tu_end: true, frame_count: 0}]

      list ->
        # Mark the last TU as end if it has frames
        last_idx = length(list) - 1

        list
        |> Enum.with_index()
        |> Enum.map(fn {tu, idx} ->
          if idx == last_idx and tu.frame_count > 0 do
            %{tu | is_tu_end: true}
          else
            tu
          end
        end)
    end
  end
end
