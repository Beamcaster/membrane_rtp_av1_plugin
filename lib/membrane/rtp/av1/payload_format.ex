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
    # Detect if this access unit starts a new coded video sequence.
    # For OBS/SVT-AV1 with continuous intra refresh, this is ANY frame with a sequence header,
    # as the decoder can start decoding from any such frame.
    is_keyframe = SequenceDetector.is_new_coded_video_sequence?(access_unit)

    # Debug logging for keyframe detection
    require Logger

    if is_keyframe do
      Logger.info(
        "🔑 AV1 Payloader: New coded video sequence (has sequence header) - setting N=1 bit"
      )
    end

    # Try to split OBUs - first Low Overhead format (from depayloader),
    # then Annex B format (for backwards compatibility with tests/legacy)
    obus =
      case OBU.split_obus_low_overhead(access_unit) do
        [^access_unit] ->
          # Low Overhead parsing failed, try Annex B format
          Logger.warning(
            "⚠️ OBU split: Low Overhead FAILED for #{byte_size(access_unit)} bytes, trying Annex B format"
          )

          annex_b_obus = OBU.split_obus(access_unit)

          if annex_b_obus == [access_unit] do
            Logger.error(
              "❌ OBU split: Both Low Overhead and Annex B parsing FAILED! Falling back to naive fragmentation"
            )
          else
            Logger.info("✅ OBU split: Annex B format detected, #{length(annex_b_obus)} OBUs")
          end

          annex_b_obus

        low_overhead_obus ->
          obu_types =
            Enum.map(low_overhead_obus, fn <<_::1, type::4, _::3, _::binary>> -> type end)

          Logger.info(
            "✅ OBU split: Low Overhead format, #{length(low_overhead_obus)} OBUs, types=#{inspect(obu_types)}"
          )

          low_overhead_obus
      end

    case obus do
      [^access_unit] ->
        # Could not parse into OBUs; fallback to naive fragmentation with headers
        Logger.warning(
          "⚠️ Using NAIVE fragmentation for #{byte_size(access_unit)} bytes (OBU parsing failed)"
        )

        naive_fragment(access_unit, max_payload, header_mode, fmtp, is_keyframe)

      list ->
        fragment_obus(list, max_payload, header_mode, fmtp, is_keyframe)
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
        # Detect TRUE keyframe (sequence header + keyframe) for N bit
        is_keyframe = SequenceDetector.is_new_coded_video_sequence?(access_unit)
        # Zero-copy: Convert IO lists to binaries at the final step
        naive_fragment(access_unit, max_payload, header_mode, fmtp, is_keyframe)
        |> Enum.map(&IO.iodata_to_binary/1)
    end
  end

  defp fragment_obus(obus, max_payload, header_mode, fmtp, is_keyframe) do
    packets =
      do_fragment_obus(obus, max_payload, {[], []}, [], header_mode, fmtp, is_keyframe)
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
  # State tuple: {rtp_obus, raw_obus_in_group} where rtp_obus are already converted to RTP format
  # is_first_packet: true for first packet (may set N=1), false for subsequent packets
  #
  # RFC 9420 COMPLIANCE:
  # - OBUs in RTP packets MUST have obu_has_size_field=0
  # - For W>0: all but last OBU have LEB128 length prefix
  # - For last OBU: no length prefix (extends to end of packet)

  # Function head with default parameter
  defp do_fragment_obus(
         obus,
         max_payload,
         state,
         acc,
         header_mode,
         fmtp,
         is_keyframe,
         is_first_packet \\ true
       )

  defp do_fragment_obus(
         [],
         _max_payload,
         {rtp_obus, raw_obus_in_group},
         acc,
         header_mode,
         fmtp,
         is_keyframe,
         is_first_packet
       ) do
    count = length(rtp_obus)

    if count == 0 do
      acc
    else
      # Build packet payload from RTP-formatted OBUs
      # All but last OBU get LEB128 length prefix per RFC 9420
      payload = build_aggregated_payload(Enum.reverse(rtp_obus))
      # N bit: set only on first packet if this is a TRUE keyframe
      n_bit = is_keyframe and is_first_packet

      header =
        encode_header(false, true, false, count, raw_obus_in_group, header_mode, fmtp, n_bit)

      pkt = [header | payload]
      [pkt | acc]
    end
  end

  defp do_fragment_obus(
         [obu | rest],
         max_payload,
         {rtp_obus, raw_obus_in_group},
         acc,
         header_mode,
         fmtp,
         is_keyframe,
         is_first_packet
       ) do
    current_count = length(rtp_obus)
    # Maximum OBU count is 3 (W field only supports 0-3)
    # W=0 means use length-prefixed format for all OBUs
    max_obu_count = 3

    # Convert OBU to RTP format (strip internal size field)
    case OBU.to_rtp_obu_element(obu) do
      {:ok, rtp_obu_no_size} ->
        # Calculate size with LEB128 prefix (for all but last OBU)
        _rtp_obu_size_with_prefix =
          byte_size(OBU.leb128_encode(byte_size(rtp_obu_no_size))) + byte_size(rtp_obu_no_size)

        rtp_obu_size_no_prefix = byte_size(rtp_obu_no_size)

        # Calculate current payload size
        current_payload_size = Enum.reduce(rtp_obus, 0, fn rtp, acc -> acc + byte_size(rtp) end)

        # Can we fit this OBU?
        # If this is not the last OBU, we need to account for LEB128 prefix
        # But we don't know if more OBUs will come, so assume this could be last (no prefix)
        # We'll add prefix when we know it's not the last one

        cond do
          # Can fit this OBU and haven't exceeded max count
          current_payload_size + rtp_obu_size_no_prefix <= max_payload and
              current_count < max_obu_count ->
            # Add to group - we'll add LEB128 prefix when flushing if not last
            do_fragment_obus(
              rest,
              max_payload,
              {[rtp_obu_no_size | rtp_obus], [obu | raw_obus_in_group]},
              acc,
              header_mode,
              fmtp,
              is_keyframe,
              is_first_packet
            )

          current_count > 0 ->
            # RFC 9420: Aggregation + Fragmentation hybrid case
            # When we have accumulated OBUs and the next OBU is too large,
            # we should include the START of the large OBU in the same packet
            # to properly signal Y=1 (continues in next packet)

            # Calculate space used by accumulated OBUs (with LEB128 prefixes for all)
            accumulated_with_prefixes =
              Enum.reduce(rtp_obus, 0, fn rtp, acc_size ->
                acc_size + byte_size(OBU.leb128_encode(byte_size(rtp))) + byte_size(rtp)
              end)

            remaining_space = max_payload - accumulated_with_prefixes

            if remaining_space > 0 and rtp_obu_size_no_prefix > max_payload do
              # Include first chunk of the large OBU in this packet
              # This creates a hybrid aggregation+fragmentation packet
              first_chunk_size = remaining_space
              first_chunk = :binary.part(rtp_obu_no_size, 0, first_chunk_size)

              remaining_obu =
                :binary.part(
                  rtp_obu_no_size,
                  first_chunk_size,
                  rtp_obu_size_no_prefix - first_chunk_size
                )

              # Build payload: all accumulated OBUs get LEB128 prefix, then first chunk (no prefix, extends to end)
              prefixed_obus =
                Enum.map(Enum.reverse(rtp_obus), fn rtp ->
                  OBU.leb128_encode(byte_size(rtp)) <> rtp
                end)

              payload = IO.iodata_to_binary(prefixed_obus ++ [first_chunk])

              # W = count + 1 (accumulated OBUs + the fragment)
              # But W maxes out at 3, so use min
              count = min(current_count + 1, 3)
              n_bit = is_keyframe and is_first_packet

              # Y=1 because the last OBU element (frame fragment) continues in next packet
              # start?=true (first fragment of this OBU), end?=false (continues), fragmented?=true
              header = encode_header_hybrid(count, n_bit, header_mode)
              pkt = [header | payload]
              acc = [pkt | acc]

              # Continue fragmenting the remaining part of this OBU
              acc =
                fragment_remaining_obu(
                  remaining_obu,
                  max_payload,
                  acc,
                  header_mode,
                  fmtp
                )

              # Process remaining OBUs
              do_fragment_obus(
                rest,
                max_payload,
                {[], []},
                acc,
                header_mode,
                fmtp,
                is_keyframe,
                false
              )
            else
              # Not enough space or OBU fits in single packet - use original flush logic
              # Build payload: all but last get LEB128 prefix
              payload = build_aggregated_payload(Enum.reverse(rtp_obus))
              count = current_count
              n_bit = is_keyframe and is_first_packet

              header =
                encode_header(
                  false,
                  true,
                  false,
                  count,
                  raw_obus_in_group,
                  header_mode,
                  fmtp,
                  n_bit
                )

              pkt = [header | payload]
              acc = [pkt | acc]
              # After first packet, set is_first_packet to false
              do_fragment_obus(
                [obu | rest],
                max_payload,
                {[], []},
                acc,
                header_mode,
                fmtp,
                is_keyframe,
                false
              )
            end

          true ->
            # Fragment this single OBU (it's too large to fit in one packet)
            acc =
              fragment_single_obu(
                # Already stripped of size field
                rtp_obu_no_size,
                max_payload,
                acc,
                header_mode,
                fmtp,
                is_keyframe,
                is_first_packet
              )

            # After fragmenting, subsequent packets have is_first_packet = false
            do_fragment_obus(
              rest,
              max_payload,
              {[], []},
              acc,
              header_mode,
              fmtp,
              is_keyframe,
              false
            )
        end

      :error ->
        # Failed to convert OBU - skip it and continue
        require Logger
        Logger.error("Failed to convert OBU to RTP format, skipping")

        do_fragment_obus(
          rest,
          max_payload,
          {rtp_obus, raw_obus_in_group},
          acc,
          header_mode,
          fmtp,
          is_keyframe,
          is_first_packet
        )
    end
  end

  # Build aggregated payload: all but last OBU get LEB128 length prefix
  defp build_aggregated_payload([]), do: <<>>
  defp build_aggregated_payload([single]), do: single

  defp build_aggregated_payload(rtp_obus) do
    {all_but_last, [last]} = Enum.split(rtp_obus, length(rtp_obus) - 1)

    prefixed =
      Enum.map(all_but_last, fn obu ->
        OBU.leb128_encode(byte_size(obu)) <> obu
      end)

    IO.iodata_to_binary(prefixed ++ [last])
  end

  defp fragment_single_obu(
         obu,
         max_payload,
         acc,
         header_mode,
         fmtp,
         is_keyframe,
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
        is_keyframe,
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
         is_keyframe,
         is_first_packet
       ) do
    remaining = total_size - offset
    chunk_size = min(max_payload, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes without copying
    chunk = :binary.part(original_obu, offset, chunk_size)

    # N bit: set only on first fragment if this is the first packet AND is a true keyframe
    # start? indicates if this is the first fragment of this OBU
    n_bit = is_keyframe and is_first_packet and start?

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
        is_keyframe,
        # After first fragment, no longer first packet
        false
      )
    end
  end

  defp naive_fragment(binary, max_payload, header_mode, fmtp, is_keyframe) do
    do_naive_fragment(
      binary,
      0,
      byte_size(binary),
      max_payload,
      [],
      true,
      header_mode,
      fmtp,
      is_keyframe
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
         _is_keyframe
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
         is_keyframe
       ) do
    remaining = total_size - offset
    chunk_size = min(max, remaining)
    is_last? = chunk_size >= remaining

    # Zero-copy: Use binary_part to reference bytes
    chunk = :binary.part(bin, offset, chunk_size)

    # N bit: set only on first packet if this is a true keyframe
    n_bit = is_keyframe and is_first

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
      is_keyframe
    )
  end

  # Helper for hybrid aggregation+fragmentation header
  # Z=0 (first packet doesn't continue from previous)
  # Y=1 (last OBU element continues in next packet)
  # W=count (number of OBU elements)
  # N=n_bit (keyframe indicator)
  defp encode_header_hybrid(count, n_bit, _header_mode) do
    # RFC 9420 hybrid packet: complete OBUs + start of fragmented OBU
    header = %Header{z: false, y: true, w: count, n: n_bit}
    Header.encode(header)
  end

  # Fragment the remaining portion of an OBU that was partially included
  # in a hybrid aggregation+fragmentation packet
  defp fragment_remaining_obu(remaining_obu, max_payload, acc, header_mode, _fmtp) do
    total = byte_size(remaining_obu)
    do_fragment_remaining(remaining_obu, 0, total, max_payload, acc, header_mode)
  end

  defp do_fragment_remaining(obu, offset, total, max_payload, acc, header_mode) do
    remaining = total - offset
    chunk_size = min(max_payload, remaining)
    is_last? = chunk_size >= remaining

    chunk = :binary.part(obu, offset, chunk_size)

    # Z=1 (continuation from previous packet)
    # Y=1 if more fragments follow, Y=0 if this is the last
    # W=1 (single OBU element extends to end of packet)
    # N=0 (not first packet of sequence)
    header = %Header{z: true, y: not is_last?, w: 1, n: false}
    pkt = [Header.encode(header) | chunk]
    acc = [pkt | acc]

    if is_last? do
      acc
    else
      do_fragment_remaining(obu, offset + chunk_size, total, max_payload, acc, header_mode)
    end
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
    # RFC 9420 Section 4.2.2:
    # - W=0: Length-prefixed format (all OBUs have LEB128 size prefix)
    # - W=1-3: That many OBU elements, last without length prefix
    # For fragmented OBUs: W=1 (single OBU element extends to end of packet)
    # For aggregated OBUs: W=count (1-3), last one has no length prefix
    w =
      cond do
        # Fragment - single OBU element fills rest of packet (W=1, no LEB128 size)
        fragmented? -> 1
        # Length-prefixed (all have sizes)
        obu_count == 0 -> 0
        # 1-3 OBUs, last without size
        obu_count in 1..3 -> obu_count
        # More than 3 OBUs, use length-prefixed format
        obu_count > 3 -> 0
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
    # RFC 9420 Section 4.2.2:
    # - W=0: Length-prefixed format (all OBUs have LEB128 size prefix)
    # - W=1-3: That many OBU elements, last without length prefix
    # For fragmented OBUs: W=1 (single OBU element extends to end of packet)
    # For aggregated OBUs: W=count (1-3), last one has no length prefix
    w =
      cond do
        # Fragment - single OBU element fills rest of packet (W=1, no LEB128 size)
        fragmented? -> 1
        # Length-prefixed (all have sizes)
        obu_count == 0 -> 0
        # 1-3 OBUs, last without size
        obu_count in 1..3 -> obu_count
        # More than 3 OBUs, use length-prefixed format
        obu_count > 3 -> 0
        true -> 0
      end

    # Use simple Header format for browser compatibility (reserved bits = 0)
    header = %Header{z: z, y: y, w: w, n: n_bit}
    Header.encode(header)
  end
end
