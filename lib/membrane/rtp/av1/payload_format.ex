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
    FMTP,
    OBUValidator,
    TUDetector,
    AggregationOptimizer,
    SequenceDetector
  }

  @doc """
  Splits a raw AV1 access unit into RTP payload-sized chunks under `mtu`,
  respecting OBU boundaries and fragmenting oversized OBUs.

  Each RTP payload starts with a 1-byte header encoded via `Membrane.RTP.AV1.Header`.

  ## Options
  - :mtu - Maximum transmission unit (default: 1200)
  - :header_mode - Header encoding mode (default: :draft)
  - :fmtp - Format parameters map
  - :validate - Enable OBU validation before fragmentation (default: false).
    When false, skips validation for better performance. Useful for payloading
    trusted encoder output. When true, validates structure and emits warnings
    for malformed OBUs.
  """
  @spec fragment(payload(), keyword()) :: [payload()] | {:error, atom(), map()}
  def fragment(access_unit, opts \\ []) when is_binary(access_unit) do
    mtu = Keyword.get(opts, :mtu, @default_mtu)
    header_mode = Keyword.get(opts, :header_mode, :spec)
    validate = Keyword.get(opts, :validate, false)
    # Use parse_legacy for backward compatibility (returns struct directly, nils on errors)
    fmtp = FMTP.parse_legacy(Keyword.get(opts, :fmtp, %{}))
    max_payload = mtu - @header_size

    if validate do
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
    else
      # Skip validation - trust the input and fragment directly
      fragment_validated(access_unit, max_payload, header_mode, fmtp)
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
  - :validate - Enable OBU validation before fragmentation (default: false)
  """
  @spec fragment_with_markers(payload(), keyword()) ::
          [{payload(), boolean()}] | {:error, atom(), map()}
  def fragment_with_markers(access_unit, opts \\ []) when is_binary(access_unit) do
    tu_aware = Keyword.get(opts, :tu_aware, true)

    # Pass all options (including validate) to fragment/2
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
    # Detect if this access unit contains a sequence header (OBU type 1)
    # If present, the first RTP packet must have N=1 bit set
    has_sequence_header = SequenceDetector.contains_sequence_header?(access_unit)

    # Debug logging for keyframe detection
    require Logger
    if has_sequence_header do
      Logger.warning("🔑 AV1 Payloader: SEQUENCE HEADER DETECTED - setting N=1 bit")
    end

    # Try to split OBUs - first Low Overhead format (from depayloader),
    # then Annex B format (for backwards compatibility with tests/legacy)
    obus =
      case OBU.split_obus_low_overhead(access_unit) do
        [^access_unit] ->
          # Low Overhead parsing failed, try Annex B format
          OBU.split_obus(access_unit)

        low_overhead_obus ->
          low_overhead_obus
      end

    case obus do
      [^access_unit] ->
        # Could not parse into OBUs; fallback to naive fragmentation with headers
        naive_fragment(access_unit, max_payload, header_mode, fmtp, has_sequence_header)

      list ->
        fragment_obus(list, max_payload, header_mode, fmtp, has_sequence_header)
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
        # Detect sequence header even in fallback case
        has_sequence_header = SequenceDetector.contains_sequence_header?(access_unit)
        # Zero-copy: Convert IO lists to binaries at the final step
        naive_fragment(access_unit, max_payload, header_mode, fmtp, has_sequence_header)
        |> Enum.map(&IO.iodata_to_binary/1)
    end
  end

  defp fragment_obus(obus, max_payload, header_mode, fmtp, has_sequence_header) do
    packets =
      do_fragment_obus(obus, max_payload, {[], 0, []}, [], header_mode, fmtp, has_sequence_header)
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
  # is_first_packet: true for first packet (may set N=1), false for subsequent packets

  # Function head with default parameter
  defp do_fragment_obus(
         obus,
         max_payload,
         state,
         acc,
         header_mode,
         fmtp,
         has_sequence_header,
         is_first_packet \\ true
       )

  defp do_fragment_obus(
         [],
         _max_payload,
         {group_iolist, count, obus_in_group},
         acc,
         header_mode,
         fmtp,
         has_sequence_header,
         is_first_packet
       ) do
    if count == 0 do
      acc
    else
      # Flatten IO list only when creating final packet
      payload = IO.iodata_to_binary(group_iolist)
      # N bit: set only on first packet if sequence header present
      n_bit = has_sequence_header and is_first_packet
      header = encode_header(false, true, false, count, obus_in_group, header_mode, fmtp, n_bit)
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
         fmtp,
         has_sequence_header,
         is_first_packet
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
          fmtp,
          has_sequence_header,
          is_first_packet
        )

      group_payload_size > 0 and count > 0 ->
        # Flush current group, then reconsider this OBU
        payload = IO.iodata_to_binary(group_iolist)
        # N bit: set only on first packet if sequence header present
        n_bit = has_sequence_header and is_first_packet
        header = encode_header(false, true, false, count, obus_in_group, header_mode, fmtp, n_bit)
        pkt = [header | payload]
        acc = [pkt | acc]
        # After first packet, set is_first_packet to false
        do_fragment_obus(
          [obu | rest],
          max_payload,
          {[], 0, []},
          acc,
          header_mode,
          fmtp,
          has_sequence_header,
          false
        )

      true ->
        # Fragment this single OBU
        acc =
          fragment_single_obu(
            obu,
            max_payload,
            acc,
            header_mode,
            fmtp,
            has_sequence_header,
            is_first_packet
          )

        # After fragmenting (which creates packets), subsequent packets have is_first_packet = false
        do_fragment_obus(
          rest,
          max_payload,
          {[], 0, []},
          acc,
          header_mode,
          fmtp,
          has_sequence_header,
          false
        )
    end
  end

  defp fragment_single_obu(
         obu,
         max_payload,
         acc,
         header_mode,
         fmtp,
         has_sequence_header,
         is_first_packet
       ) do
    total = byte_size(obu)
    # Zero-copy: Use binary references instead of splitting
    packets =
      build_fragment_packets(
        0,
        total,
        obu,
        max_payload,
        [],
        true,
        header_mode,
        fmtp,
        has_sequence_header,
        is_first_packet
      )

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
         fmtp,
         has_sequence_header,
         is_first_packet
       ) do
    remaining = total_size - offset
    chunk_size = min(max_payload, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes without copying
    chunk = :binary.part(original_obu, offset, chunk_size)

    # N bit: set only on first fragment if this is the first packet and has sequence header
    # start? indicates if this is the first fragment of this OBU
    n_bit = has_sequence_header and is_first_packet and start?

    # Zero-copy: Build packet as IO list [header | chunk] instead of binary concatenation
    header = encode_header(start?, is_last?, true, 0, [original_obu], header_mode, fmtp, n_bit)
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
        fmtp,
        has_sequence_header,
        # After first fragment, no longer first packet
        false
      )
    end
  end

  defp naive_fragment(binary, max_payload, header_mode, fmtp, has_sequence_header) do
    do_naive_fragment(
      binary,
      0,
      byte_size(binary),
      max_payload,
      [],
      true,
      header_mode,
      fmtp,
      has_sequence_header
    )
  end

  # Zero-copy: Use offset-based approach instead of binary splitting
  defp do_naive_fragment(
         _bin,
         offset,
         total_size,
         _max,
         acc,
         _is_first,
         _header_mode,
         _fmtp,
         _has_sequence_header
       )
       when offset >= total_size do
    Enum.reverse(acc)
  end

  defp do_naive_fragment(
         bin,
         offset,
         total_size,
         max,
         acc,
         is_first,
         header_mode,
         fmtp,
         has_sequence_header
       ) do
    remaining = total_size - offset
    chunk_size = min(max, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes
    chunk = :binary.part(bin, offset, chunk_size)

    # N bit: set only on first packet if sequence header present
    n_bit = has_sequence_header and is_first

    # Build packet as IO list
    # fragmented? = true because we're fragmenting (multiple packets)
    header = encode_header(is_first, is_last?, true, 0, [], header_mode, fmtp, n_bit)
    pkt = [header | chunk]

    do_naive_fragment(
      bin,
      offset + chunk_size,
      total_size,
      max,
      [pkt | acc],
      false,
      header_mode,
      fmtp,
      has_sequence_header
    )
  end

  defp encode_header(start?, end?, fragmented?, obu_count, _obus, :draft, _fmtp, n_bit) do
    # RFC 9420 compliant header encoding:
    # Z = continuation from previous packet (first OBU is fragment continuation)
    # Y = continues in next packet (last OBU will continue)
    # W = number of OBU elements (0 = length prefixed, 1-3 = that many OBUs)
    # N = new coded video sequence (keyframe)

    # Z bit: set if this packet starts with a continuation of previous OBU
    z = not start? and fragmented?

    # Y bit: set if last OBU will continue in next packet
    y = not end? and fragmented?

    # W bit: count of OBU elements in packet
    # For fragmented single OBU: W=0 (the fragment fills the packet, no length field needed)
    # For aggregated OBUs: W=count (1-3), last one has no length field
    w =
      cond do
        fragmented? -> 0  # Fragment - OBU fills rest of packet
        obu_count == 0 -> 0  # Length-prefixed (all have sizes)
        obu_count in 1..3 -> obu_count  # 1-3 OBUs, last without size
        obu_count > 3 -> 0  # More than 3 OBUs, use length-prefixed format
        true -> 0
      end

    header = %Header{z: z, y: y, w: w, n: n_bit}
    Header.encode(header)
  end

  defp encode_header(start?, end?, fragmented?, obu_count, _obus, :spec, _fmtp, n_bit) do
    # RFC 9420 compliant header encoding:
    # Z = continuation from previous packet (first OBU is fragment continuation)
    # Y = continues in next packet (last OBU will continue)
    # W = number of OBU elements (0 = length prefixed, 1-3 = that many OBUs)
    # N = new coded video sequence (keyframe)
    # Bits 2-0: RESERVED (must be 0 for browser compatibility)

    # Z bit: set if this packet starts with a continuation of previous OBU
    z = not start? and fragmented?

    # Y bit: set if last OBU will continue in next packet
    y = not end? and fragmented?

    # W bit: count of OBU elements in packet
    # For fragmented single OBU: W=0 (the fragment fills the packet, no length field needed)
    # For aggregated OBUs: W=count (1-3), last one has no length field
    w =
      cond do
        fragmented? -> 0  # Fragment - OBU fills rest of packet
        obu_count == 0 -> 0  # Length-prefixed (all have sizes)
        obu_count in 1..3 -> obu_count  # 1-3 OBUs, last without size
        obu_count > 3 -> 0  # More than 3 OBUs, use length-prefixed format
        true -> 0
      end

    # Use simple Header format for browser compatibility (reserved bits = 0)
    header = %Header{z: z, y: y, w: w, n: n_bit}
    Header.encode(header)
  end
end
