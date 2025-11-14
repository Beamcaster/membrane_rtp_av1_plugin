defmodule Membrane.RTP.AV1.PayloadFormat do
  @moduledoc """
  Utilities for AV1 RTP payload formatting.

  NOTE: Minimal OBU-aware fragmentation with a simple 1-byte header to indicate:
  - start/end of fragment groups
  - whether packet carries fragmented data
  - number of complete OBUs aggregated in packet
  """

  @type payload :: binary()

  @default_mtu 1200
  @header_size 1

  alias Membrane.RTP.AV1.{
    OBU,
    Header,
    FullHeader,
    FMTP,
    ScalabilityStructure,
    OBUHeader,
    OBUValidator,
    TUDetector,
    AggregationOptimizer
  }

  @doc """
  Splits a raw AV1 access unit into RTP payload-sized chunks under `mtu`,
  respecting OBU boundaries and fragmenting oversized OBUs.

  Each RTP payload starts with a 1-byte header encoded via `Membrane.RTP.AV1.Header`.

  Validates OBU structure before packetization and emits telemetry events
  for malformed OBUs.
  """
  @spec fragment(payload(), keyword()) :: [payload()] | {:error, atom(), map()}
  def fragment(access_unit, opts \\ []) when is_binary(access_unit) do
    mtu = Keyword.get(opts, :mtu, @default_mtu)
    header_mode = Keyword.get(opts, :header_mode, :draft)
    # Use parse_legacy for backward compatibility (returns struct directly, nils on errors)
    fmtp = FMTP.parse_legacy(Keyword.get(opts, :fmtp, %{}))
    max_payload = mtu - @header_size

    # Validate OBU boundaries before processing
    case OBUValidator.validate_access_unit(access_unit) do
      :ok ->
        fragment_validated(access_unit, max_payload, header_mode, fmtp)

      {:error, reason, context} = error ->
        # Log validation error
        require Membrane.Logger

        Membrane.Logger.warning(
          "OBU validation failed: #{OBUValidator.error_message(error)}. " <>
            "Attempting fallback fragmentation."
        )

        # Attempt fallback fragmentation for backwards compatibility
        fallback_fragment(access_unit, max_payload, header_mode, fmtp, reason, context)
    end
  end

  @doc """
  Splits an access unit into RTP packets with TU-aware marker bit assignment.

  Returns a list of {payload, marker} tuples where marker indicates TU boundaries.

  ## Options
  - :mtu - Maximum transmission unit (default: 1200)
  - :header_mode - Header encoding mode (default: :draft)
  - :fmtp - Format parameters map
  - :tu_aware - Enable TU detection for marker bits (default: true)
  """
  @spec fragment_with_markers(payload(), keyword()) ::
          [{payload(), boolean()}] | {:error, atom(), map()}
  def fragment_with_markers(access_unit, opts \\ []) when is_binary(access_unit) do
    tu_aware = Keyword.get(opts, :tu_aware, true)

    case fragment(access_unit, opts) do
      {:error, _, _} = error ->
        error

      packets when is_list(packets) ->
        if tu_aware do
          tus = TUDetector.detect_tu_boundaries(access_unit)
          TUDetector.assign_markers(packets, tus)
        else
          # Simple case: marker on last packet only
          packets
          |> Enum.with_index(1)
          |> Enum.map(fn {pkt, idx} -> {pkt, idx == length(packets)} end)
        end
    end
  end

  defp fragment_validated(access_unit, max_payload, header_mode, fmtp) do
    obus = OBU.split_obus(access_unit)

    case obus do
      [^access_unit] ->
        # Could not parse into OBUs; fallback to naive fragmentation with headers
        naive_fragment(access_unit, max_payload, header_mode, fmtp)

      list ->
        fragment_obus(list, max_payload, header_mode, fmtp)
    end
    # Zero-copy: Convert IO lists to binaries only at the final step
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp fallback_fragment(access_unit, max_payload, header_mode, fmtp, reason, _context) do
    # For certain errors, still attempt fragmentation
    case reason do
      :partial_obu_at_boundary ->
        # This is critical - cannot safely fragment partial OBUs
        {:error, reason,
         %{
           message: "Cannot fragment access unit with partial OBU at boundary",
           size: byte_size(access_unit)
         }}

      _ ->
        # Other errors: try naive fragmentation as best effort
        # Zero-copy: Convert IO lists to binaries at the final step
        naive_fragment(access_unit, max_payload, header_mode, fmtp)
        |> Enum.map(&IO.iodata_to_binary/1)
    end
  end

  defp fragment_obus(obus, max_payload, header_mode, fmtp) do
    packets =
      do_fragment_obus(obus, max_payload, {[], 0, []}, [], header_mode, fmtp)
      |> Enum.reverse()

    # Emit telemetry for aggregation metrics
    emit_aggregation_telemetry(obus, packets, max_payload)

    packets
  end

  defp emit_aggregation_telemetry(obus, _packets, max_payload) do
    {:ok, metrics} =
      AggregationOptimizer.analyze(Enum.join(obus), mtu: max_payload + 1, header_size: 1)

    :telemetry.execute(
      [:membrane_rtp_av1, :aggregation, :complete],
      %{
        total_obus: metrics.total_obus,
        total_packets: metrics.total_packets,
        aggregated_packets: metrics.aggregated_packets,
        average_obus_per_packet: metrics.average_obus_per_packet,
        aggregation_ratio: metrics.aggregation_ratio,
        payload_efficiency: metrics.payload_efficiency
      },
      %{
        mtu: max_payload
      }
    )
  end

  # Accumulate complete OBUs as long as they fit; if one OBU is too large,
  # fragment it across packets.
  # State tuple: {group_iolist, count, obus_in_group}
  # Zero-copy: Use IO lists for accumulation instead of binary concatenation
  defp do_fragment_obus(
         [],
         _max_payload,
         {group_iolist, count, obus_in_group},
         acc,
         header_mode,
         fmtp
       ) do
    if count == 0 do
      acc
    else
      # Flatten IO list only when creating final packet
      payload = IO.iodata_to_binary(group_iolist)
      header = encode_header(false, true, false, count, obus_in_group, header_mode, fmtp)
      pkt = [header | payload]
      [pkt | acc]
    end
  end

  defp do_fragment_obus(
         [obu | rest],
         max_payload,
         {group_iolist, count, obus_in_group},
         acc,
         header_mode,
         fmtp
       ) do
    # Calculate current group size by flattening IO list
    group_payload_size = IO.iodata_length(group_iolist)
    obu_size = byte_size(obu)
    # Maximum OBU count is 31 (5 bits in header)
    max_obu_count = 31

    cond do
      # Can fit this OBU and haven't exceeded max count
      group_payload_size + obu_size <= max_payload and count < max_obu_count ->
        # Zero-copy: Append to IO list instead of binary concatenation
        new_group = [group_iolist | obu]

        do_fragment_obus(
          rest,
          max_payload,
          {new_group, count + 1, [obu | obus_in_group]},
          acc,
          header_mode,
          fmtp
        )

      group_payload_size > 0 and count > 0 ->
        # Flush current group, then reconsider this OBU
        payload = IO.iodata_to_binary(group_iolist)
        header = encode_header(false, true, false, count, obus_in_group, header_mode, fmtp)
        pkt = [header | payload]
        acc = [pkt | acc]
        do_fragment_obus([obu | rest], max_payload, {[], 0, []}, acc, header_mode, fmtp)

      true ->
        # Fragment this single OBU
        acc = fragment_single_obu(obu, max_payload, acc, header_mode, fmtp)
        do_fragment_obus(rest, max_payload, {[], 0, []}, acc, header_mode, fmtp)
    end
  end

  defp fragment_single_obu(obu, max_payload, acc, header_mode, fmtp) do
    total = byte_size(obu)
    # Zero-copy: Use binary references instead of splitting
    packets = build_fragment_packets(0, total, obu, max_payload, [], true, header_mode, fmtp)
    Enum.reduce(packets, acc, fn pkt, a -> [pkt | a] end)
  end

  # Updated to avoid intermediate binary creation by using offset into original OBU
  defp build_fragment_packets(
         offset,
         total_size,
         original_obu,
         max_payload,
         acc,
         start?,
         header_mode,
         fmtp
       ) do
    remaining = total_size - offset
    chunk_size = min(max_payload, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes without copying
    chunk = :binary.part(original_obu, offset, chunk_size)

    # Zero-copy: Build packet as IO list [header | chunk] instead of binary concatenation
    header = encode_header(start?, is_last?, true, 0, [original_obu], header_mode, fmtp)
    packet = [header | chunk]
    acc = [packet | acc]

    if is_last? do
      Enum.reverse(acc)
    else
      build_fragment_packets(
        offset + chunk_size,
        total_size,
        original_obu,
        max_payload,
        acc,
        false,
        header_mode,
        fmtp
      )
    end
  end

  defp naive_fragment(binary, max_payload, header_mode, fmtp) do
    do_naive_fragment(binary, 0, byte_size(binary), max_payload, [], true, header_mode, fmtp)
  end

  # Zero-copy: Use offset-based approach instead of binary splitting
  defp do_naive_fragment(_bin, offset, total_size, _max, acc, _is_first, _header_mode, _fmtp)
       when offset >= total_size do
    Enum.reverse(acc)
  end

  defp do_naive_fragment(bin, offset, total_size, max, acc, is_first, header_mode, fmtp) do
    remaining = total_size - offset
    chunk_size = min(max, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes
    chunk = :binary.part(bin, offset, chunk_size)

    # Build packet as IO list
    # fragmented? = true because we're fragmenting (multiple packets)
    header = encode_header(is_first, is_last?, true, 0, [], header_mode, fmtp)
    pkt = [header | chunk]

    do_naive_fragment(
      bin,
      offset + chunk_size,
      total_size,
      max,
      [pkt | acc],
      false,
      header_mode,
      fmtp
    )
  end

  defp encode_header(start?, end?, fragmented?, obu_count, _obus, :draft, _fmtp) do
    header = %Header{start?: start?, end?: end?, fragmented?: fragmented?, obu_count: obu_count}
    Header.encode(header)
  end

  defp encode_header(start?, end?, fragmented?, obu_count, obus, :spec, fmtp) do
    w =
      cond do
        not fragmented? -> 0
        start? and not end? -> 1
        not start? and not end? -> 2
        not start? and end? -> 3
        # start? and end? and fragmented? should not happen in normal cases
        # but treat as error/edge case - use W=0
        true -> 0
      end

    # CM bit: Use OBU type analysis if OBUs available, fallback to fmtp.cm or count hint
    c = determine_cm_bit(obus, obu_count, fmtp)

    # IDS present if tid/lid provided
    {m, tid, lid} =
      case {fmtp.temporal_id, fmtp.spatial_id} do
        {t, l} when is_integer(t) or is_integer(l) ->
          {true, t || 0, l || 0}

        _ ->
          {false, nil, nil}
      end

    # SS present if provided in fmtp and this is the start
    {z, ss} =
      case {start?, fmtp.scalability_structure} do
        {true, %ScalabilityStructure{} = structure} ->
          {true, structure}

        _ ->
          {false, nil}
      end

    FullHeader.encode(%FullHeader{
      z: z,
      y: start?,
      w: w,
      n: false,
      c: c,
      m: m,
      temporal_id: tid,
      spatial_id: lid,
      scalability_structure: ss
    })
  end

  # Determines CM bit based on OBU types
  defp determine_cm_bit(obus, obu_count, fmtp) when is_list(obus) and length(obus) > 0 do
    # Use OBU header analysis for accurate CM determination
    case OBUHeader.determine_cm_from_obus(obus) do
      {:ok, cm} ->
        cm

      {:error, _reason} ->
        # Fallback to fmtp or heuristic if parsing fails
        fallback_cm(obu_count, fmtp)
    end
  end

  defp determine_cm_bit(_obus, obu_count, fmtp) do
    # No OBUs or empty list - use fallback
    fallback_cm(obu_count, fmtp)
  end

  defp fallback_cm(obu_count, fmtp) do
    case fmtp.cm do
      0 -> 0
      1 -> 1
      _ -> if obu_count > 0, do: 1, else: 0
    end
  end
end
