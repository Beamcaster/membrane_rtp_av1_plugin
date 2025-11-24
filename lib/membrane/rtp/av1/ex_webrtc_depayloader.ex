defmodule Membrane.RTP.AV1.ExWebRTCDepayloader do
  @moduledoc """
  RTP depayloader for AV1 video streams using ExWebRTC-style parsing.

  This element reassembles AV1 temporal units from RTP packets according to
  [RTP Payload Format for AV1 v1.0.0](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html).

  ## Input/Output

  - **Input**: RTP packets (`Membrane.RTP` format)
  - **Output**: AV1 temporal units (`Membrane.RTP.AV1.Format`)

  ## Features

  - Handles OBU fragmentation via Z/Y bits
  - Assembles complete temporal units when marker bit is set
  - Adds temporal delimiter OBU to output temporal units
  - Handles packet reordering within configurable buffer size
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, RTP}
  alias Membrane.RTP.AV1.Format
  alias Membrane.RTP.AV1.ExWebRTC.{LEB128, Payload}

  # Import Bitwise for OBU parsing operations
  import Bitwise

  # OBU type constants
  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_frame 6

  def_input_pad :input,
    accepted_format: RTP,
    flow_control: :auto

  def_output_pad :output,
    accepted_format: Format,
    flow_control: :auto

  def_options max_reorder_buffer: [
                spec: pos_integer(),
                default: 10,
                description: "Maximum packets to buffer for reordering per RTP timestamp"
              ],
              require_sequence_header: [
                spec: boolean(),
                default: true,
                description:
                  "When true, cache and prepend sequence headers for AV1 decoder initialization. " <>
                    "If a frame arrives without a cached sequence header, a keyframe request will be emitted. " <>
                    "Enable this for decoders that require sequence header initialization (e.g., rav1d)."
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      # Current temporal unit being assembled
      current_temporal_unit: nil,
      current_timestamp: nil,
      # OBU fragment being assembled (across packets)
      current_obu_fragment: nil,
      # Configuration
      max_reorder_buffer: opts.max_reorder_buffer,
      require_sequence_header: opts.require_sequence_header,
      # Stream format tracking
      stream_format_sent: false,
      # Sequence header caching for AV1 decoder initialization
      cached_sequence_header: nil,
      waiting_for_keyframe: false
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    # RTP Parser provides RemoteStream format
    # We'll send our own stream format on first output
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    Membrane.Logger.debug("""
    RTP packet received:
    - Cached seq header: #{state.cached_sequence_header != nil}
    - Waiting for keyframe: #{state.waiting_for_keyframe}
    """)

    %Buffer{payload: payload, pts: pts, metadata: metadata} = buffer

    # Handle padding-only packets
    if payload == <<>> do
      {[], state}
    else
      marker = get_in(metadata, [:rtp, :marker]) || false
      rtp_timestamp = get_in(metadata, [:rtp, :timestamp]) || 0

      case Payload.parse(payload) do
        {:ok, av1_payload} ->
          case av1_payload.payload do
            <<header::8, _::binary>> ->
              obu_type = header >>> 3 &&& 0x0F
              Membrane.Logger.debug("Received OBU type: #{obu_type} (#{obu_type_name(obu_type)})")
            _ ->
              :ok
          end

          do_depayload(state, av1_payload, rtp_timestamp, marker, pts)

        {:error, reason} ->
          Membrane.Logger.warning("""
          Couldn't parse AV1 payload, reason: #{reason}. \
          Resetting depayloader state. Payload: #{inspect(payload)}.\
          """)

          {[], reset_depayloader(state)}
      end
    end
  end

  defp obu_type_name(1), do: "SEQUENCE_HEADER"
  defp obu_type_name(2), do: "TEMPORAL_DELIMITER"
  defp obu_type_name(3), do: "FRAME_HEADER"
  defp obu_type_name(6), do: "FRAME"
  defp obu_type_name(n), do: "TYPE_#{n}"

  # Main depayloading logic using Z/Y bits for OBU fragmentation
  defp do_depayload(state, av1_payload, timestamp, marker, pts) do
    # Handle OBU fragments based on Z and Y bits
    # Z=0, Y=0: Single complete OBU
    # Z=0, Y=1: First fragment of an OBU
    # Z=1, Y=0: Last fragment of an OBU
    # Z=1, Y=1: Middle fragment of an OBU

    state =
      case {av1_payload.z, av1_payload.y, state.current_obu_fragment} do
        # Single complete OBU
        {0, 0, nil} ->
          append_obu(state, timestamp, av1_payload.payload)

        # Single complete OBU, but we have a fragment (incomplete previous OBU)
        {0, 0, _fragment} ->
          Membrane.Logger.debug(
            "Received complete OBU while having incomplete fragment. Dropping fragment."
          )

          state
          |> reset_obu_fragment()
          |> append_obu(timestamp, av1_payload.payload)

        # First fragment of an OBU
        {0, 1, nil} ->
          start_obu_fragment(state, timestamp, av1_payload.payload)

        # First fragment, but we already have a fragment
        {0, 1, _fragment} ->
          Membrane.Logger.debug(
            "Received first OBU fragment while having incomplete fragment. Dropping old fragment."
          )

          state
          |> reset_obu_fragment()
          |> start_obu_fragment(timestamp, av1_payload.payload)

        # Last fragment of an OBU
        {1, 0, fragment}
        when fragment != nil and timestamp == state.current_timestamp ->
          complete_obu = fragment <> av1_payload.payload

          state
          |> reset_obu_fragment()
          |> append_obu(timestamp, complete_obu)

        # Last fragment, but no current fragment or wrong timestamp
        {1, 0, _} ->
          Membrane.Logger.debug("Received last OBU fragment without matching first fragment. Dropping.")
          reset_obu_fragment(state)

        # Middle fragment of an OBU
        {1, 1, fragment}
        when fragment != nil and timestamp == state.current_timestamp ->
          %{state | current_obu_fragment: fragment <> av1_payload.payload}

        # Middle fragment, but no current fragment or wrong timestamp
        {1, 1, _} ->
          Membrane.Logger.debug("Received middle OBU fragment without matching first fragment. Dropping.")
          reset_obu_fragment(state)
      end

    # Check if we have a complete temporal unit (marker bit set)
    case {state.current_temporal_unit, marker} do
      {nil, _} ->
        {[], state}

      {temporal_unit, true} ->
        # Add temporal delimiter OBU at the beginning
        complete_temporal_unit = add_temporal_delimiter() <> temporal_unit

        # Build output buffer
        {actions, new_state} = build_output(complete_temporal_unit, pts, state)

        {actions, reset_depayloader(new_state)}

      {_temporal_unit, false} ->
        {[], state}
    end
  end

  defp append_obu(state, timestamp, obu_data) do
    # Strip any temporal delimiter OBUs from incoming data
    # We add a canonical temporal delimiter at the end in do_depayload/5
    filtered_obu_data = strip_temporal_delimiters(obu_data)

    # If all data was temporal delimiters, nothing to append
    if filtered_obu_data == <<>> do
      state
    else
      # Cache sequence header as soon as we see it in any complete OBU
      state = maybe_cache_sequence_header(state, filtered_obu_data)

      cond do
        state.current_temporal_unit == nil ->
          %{state | current_temporal_unit: filtered_obu_data, current_timestamp: timestamp}

        timestamp != state.current_timestamp ->
          Membrane.Logger.debug("""
          Received OBU with different timestamp without finishing previous temporal unit. \
          Dropping previous temporal unit.\
          """)

          %{state | current_temporal_unit: filtered_obu_data, current_timestamp: timestamp}

        true ->
          %{
            state
            | current_temporal_unit: state.current_temporal_unit <> filtered_obu_data
          }
      end
    end
  end

  # Check if OBU data contains a sequence header and cache it immediately
  defp maybe_cache_sequence_header(state, obu_data) do
    if state.require_sequence_header and state.cached_sequence_header == nil do
      case extract_sequence_header(obu_data) do
        nil ->
          state

        seq_header ->
          Membrane.Logger.info("Found and cached sequence header (#{byte_size(seq_header)} bytes)")
          %{state | cached_sequence_header: seq_header, waiting_for_keyframe: false}
      end
    else
      state
    end
  end

  defp start_obu_fragment(state, timestamp, fragment) do
    if state.current_temporal_unit == nil or timestamp != state.current_timestamp do
      if state.current_temporal_unit != nil do
        Membrane.Logger.debug("""
        Starting OBU fragment with different timestamp. Dropping previous temporal unit.\
        """)
      end

      %{
        state
        | current_obu_fragment: fragment,
          current_timestamp: timestamp,
          current_temporal_unit: nil
      }
    else
      %{state | current_obu_fragment: fragment}
    end
  end

  defp reset_obu_fragment(state) do
    %{state | current_obu_fragment: nil}
  end

  defp reset_depayloader(state) do
    %{state | current_temporal_unit: nil, current_timestamp: nil, current_obu_fragment: nil}
  end

  # Creates a temporal delimiter OBU
  # According to AV1 spec section 5.5:
  # - obu_forbidden_bit = 0 (1 bit)
  # - obu_type = 2 (temporal delimiter) (4 bits)
  # - obu_extension_flag = 0 (1 bit)
  # - obu_has_size_field = 1 (1 bit)
  # - obu_reserved_1bit = 0 (1 bit)
  # - obu_size = 0 (since temporal delimiter has no payload)
  defp add_temporal_delimiter do
    <<0::1, @obu_temporal_delimiter::4, 0::1, 1::1, 0::1, 0::8>>
  end

  defp build_output(temporal_unit, pts, state) do
    # Send stream format on first output if not sent
    format_actions =
      if not state.stream_format_sent do
        [stream_format: {:output, %Format{}}]
      else
        []
      end

    # Apply sequence header caching logic if enabled
    {buffer_actions, new_state} =
      build_output_with_sequence_header(temporal_unit, pts, state)

    new_state = %{new_state | stream_format_sent: true}

    {format_actions ++ buffer_actions, new_state}
  end

  # =============================================================================
  # OBU Parsing Utilities
  # =============================================================================

  # Parse OBU header and return structured information
  defp parse_obu_header(<<header::8, rest::binary>>) do
    # Check if forbidden bit is 0 (valid OBU)
    forbidden_bit = header >>> 7
    if forbidden_bit != 0 do
      {:error, :invalid_obu}
    else
      obu_type = header >>> 3 &&& 0x0F
      has_extension = (header &&& 0x04) != 0
      has_size = (header &&& 0x02) != 0

      {rest_after_ext, extension_bytes} =
        if has_extension do
          case rest do
            <<_ext::8, r::binary>> -> {r, 1}
            _ -> {rest, 0}
          end
        else
          {rest, 0}
        end

      {:ok,
       %{
         type: obu_type,
         has_size: has_size,
         rest: rest_after_ext,
         header_bytes: 1 + extension_bytes
       }}
    end
  end

  defp parse_obu_header(_), do: {:error, :invalid_obu}

  # Read OBU size using LEB128 module
  defp read_obu_size(data) do
    case LEB128.read(data) do
      {:ok, size_bytes, value} -> {:ok, value, size_bytes}
      _ -> {:error, :invalid_size}
    end
  end

  # Find the next OBU boundary by scanning for a valid OBU header
  # Returns {obu_data, rest} or {data, <<>>} if no next OBU found
  defp find_next_obu_boundary(data) do
    find_next_obu_boundary_impl(data, 1)
  end

  defp find_next_obu_boundary_impl(data, offset) when offset >= byte_size(data) do
    {data, <<>>}
  end

  defp find_next_obu_boundary_impl(data, offset) do
    case binary_part(data, offset, byte_size(data) - offset) do
      <<header::8, _rest::binary>> = potential_obu ->
        # Check if this could be a valid OBU header
        forbidden_bit = header >>> 7
        obu_type = header >>> 3 &&& 0x0F

        # Valid OBU types are 0-15, and forbidden bit must be 0
        if forbidden_bit == 0 and obu_type <= 15 do
          # Found potential OBU boundary
          {binary_part(data, 0, offset), potential_obu}
        else
          find_next_obu_boundary_impl(data, offset + 1)
        end

      _ ->
        {data, <<>>}
    end
  end

  # Get the size of an OBU without a size field
  # For RTP, we need special handling for each OBU type
  defp get_obu_size_without_field(obu_info, data) do
    case obu_info.type do
      # Temporal delimiter has no payload
      @obu_temporal_delimiter ->
        {:ok, 0}

      # For other types without size field in RTP:
      # - If this is the last OBU, it consumes the rest of the data
      # - Otherwise, we need to find the next OBU boundary
      _ ->
        # Try to find next OBU
        {obu_data, _rest} = find_next_obu_boundary(data)
        {:ok, byte_size(obu_data) - obu_info.header_bytes}
    end
  end

  # Iterate through OBUs with an accumulator function
  defp iterate_obus(data, acc, fun), do: iterate_obus_impl(data, acc, fun)

  defp iterate_obus_impl(<<>>, acc, _fun), do: acc

  defp iterate_obus_impl(data, acc, fun) do
    with {:ok, obu_info} <- parse_obu_header(data) do
      acc = fun.(obu_info.type, acc)

      # Determine how to skip to the next OBU
      skip_result =
        if obu_info.has_size do
          # OBU has size field - read it with LEB128
          case read_obu_size(obu_info.rest) do
            {:ok, obu_size, size_bytes} ->
              {:ok, size_bytes + obu_size}
            _ ->
              :error
          end
        else
          # OBU doesn't have size field - need special handling
          case get_obu_size_without_field(obu_info, obu_info.rest) do
            {:ok, obu_payload_size} ->
              {:ok, obu_payload_size}
            _ ->
              :error
          end
        end

      case skip_result do
        {:ok, skip_bytes} ->
          if byte_size(obu_info.rest) >= skip_bytes do
            next_data = binary_part(obu_info.rest, skip_bytes, byte_size(obu_info.rest) - skip_bytes)
            iterate_obus_impl(next_data, acc, fun)
          else
            acc
          end

        :error ->
          acc
      end
    else
      _ -> acc
    end
  end

  # Strip temporal delimiter OBUs from data, keeping all other OBUs
  defp strip_temporal_delimiters(data), do: strip_temporal_delimiters_impl(data, <<>>)

  defp strip_temporal_delimiters_impl(<<>>, acc), do: acc

  defp strip_temporal_delimiters_impl(data, acc) do
    case parse_obu_header(data) do
      {:ok, obu_info} ->
        # Calculate OBU total size
        size_result =
          if obu_info.has_size do
            case read_obu_size(obu_info.rest) do
              {:ok, obu_size, size_bytes} ->
                {:ok, obu_info.header_bytes + size_bytes + obu_size}
              _ ->
                :error
            end
          else
            case get_obu_size_without_field(obu_info, obu_info.rest) do
              {:ok, obu_payload_size} ->
                {:ok, obu_info.header_bytes + obu_payload_size}
              _ ->
                :error
            end
          end

        case size_result do
          {:ok, total_size} when byte_size(data) >= total_size ->
            obu_data = binary_part(data, 0, total_size)
            next_data = binary_part(data, total_size, byte_size(data) - total_size)

            # Skip temporal delimiters, keep everything else
            new_acc =
              if obu_info.type == @obu_temporal_delimiter do
                acc
              else
                acc <> obu_data
              end

            strip_temporal_delimiters_impl(next_data, new_acc)

          {:ok, _total_size} ->
            # Not enough data for full OBU, keep what we have if not a TD
            if obu_info.type == @obu_temporal_delimiter, do: acc, else: acc <> data

          :error ->
            # Can't parse, keep as-is
            acc <> data
        end

      _ ->
        # Invalid OBU header, keep data as-is
        acc <> data
    end
  end

  # Find OBU by type and extract it
  defp find_obu_by_type(data, target_type), do: find_obu_by_type_impl(data, target_type)

  defp find_obu_by_type_impl(<<>>, _), do: nil

  defp find_obu_by_type_impl(data, target_type) do
    case parse_obu_header(data) do
      {:ok, obu_info} ->
        if obu_info.type == target_type do
          # Found the target OBU type
          if obu_info.has_size do
            # Has size field - extract using LEB128
            case read_obu_size(obu_info.rest) do
              {:ok, obu_size, size_bytes} ->
                total_size = obu_info.header_bytes + size_bytes + obu_size

                if byte_size(data) >= total_size do
                  binary_part(data, 0, total_size)
                else
                  nil
                end

              _ ->
                nil
            end
          else
            # No size field - extract based on OBU type or next boundary
            case get_obu_size_without_field(obu_info, obu_info.rest) do
              {:ok, obu_payload_size} ->
                total_size = obu_info.header_bytes + obu_payload_size

                if byte_size(data) >= total_size do
                  binary_part(data, 0, total_size)
                else
                  # If we can't get full size, return what we have
                  data
                end

              _ ->
                nil
            end
          end
        else
          # Not the target type, skip to next OBU
          skip_result =
            if obu_info.has_size do
              case read_obu_size(obu_info.rest) do
                {:ok, obu_size, size_bytes} ->
                  {:ok, size_bytes + obu_size}
                _ ->
                  :error
              end
            else
              case get_obu_size_without_field(obu_info, obu_info.rest) do
                {:ok, obu_payload_size} ->
                  {:ok, obu_payload_size}
                _ ->
                  :error
              end
            end

          case skip_result do
            {:ok, skip_bytes} ->
              if byte_size(obu_info.rest) >= skip_bytes do
                next_data = binary_part(obu_info.rest, skip_bytes, byte_size(obu_info.rest) - skip_bytes)
                find_obu_by_type_impl(next_data, target_type)
              else
                nil
              end

            :error ->
              nil
          end
        end

      _ ->
        nil
    end
  end

  # =============================================================================
  # Sequence Header Caching
  # AV1 decoders need the sequence header OBU to initialize their decoding context.
  # =============================================================================

  defp build_output_with_sequence_header(temporal_unit, pts, state) do
    if not state.require_sequence_header do
      # Sequence header management disabled - pass through as-is
      buffer = %Buffer{
        payload: temporal_unit,
        pts: pts,
        metadata: %{av1: %{temporal_unit_size: byte_size(temporal_unit)}}
      }

      {[buffer: {:output, buffer}], state}
    else
      # Sequence header management enabled
      {has_seq_header, has_frame} = analyze_obus(temporal_unit)

      # Cache sequence header if present
      state =
        if has_seq_header do
          seq_header = extract_sequence_header(temporal_unit)

          if seq_header != nil do
            %{state | cached_sequence_header: seq_header, waiting_for_keyframe: false}
          else
            state
          end
        else
          state
        end

      cond do
        # No sequence header cached and we have frames - request keyframe
        state.cached_sequence_header == nil and has_frame ->
          Membrane.Logger.warning(
            "No sequence header available, requesting keyframe. " <>
              "AV1 decoders need sequence header to initialize."
          )

          {[event: {:output, %Membrane.KeyframeRequestEvent{}}],
           %{state | waiting_for_keyframe: true}}

        # Have cached sequence header but payload doesn't have one - prepend it
        state.cached_sequence_header != nil and not has_seq_header and has_frame ->
          # Output: temporal_delimiter + cached_sequence_header + rest of temporal_unit
          # The temporal_unit already has temporal delimiter prepended in do_depayload,
          # so we insert the sequence header after the temporal delimiter
          complete_payload = insert_sequence_header_after_delimiter(
            temporal_unit,
            state.cached_sequence_header
          )

          buffer = %Buffer{
            payload: complete_payload,
            pts: pts,
            metadata: %{av1: %{temporal_unit_size: byte_size(complete_payload)}}
          }

          {[buffer: {:output, buffer}], state}

        # Normal case - has sequence header or is not a frame
        true ->
          buffer = %Buffer{
            payload: temporal_unit,
            pts: pts,
            metadata: %{av1: %{temporal_unit_size: byte_size(temporal_unit)}}
          }

          {[buffer: {:output, buffer}], state}
      end
    end
  end

  # Insert sequence header after the temporal delimiter (first 2 bytes)
  defp insert_sequence_header_after_delimiter(temporal_unit, sequence_header) do
    # Temporal delimiter is 2 bytes: <<0x12, 0x00>>
    <<delimiter::binary-size(2), rest::binary>> = temporal_unit
    delimiter <> sequence_header <> rest
  end

  # Analyze OBUs in data to check for presence of sequence header and frame OBUs
  defp analyze_obus(data) do
    iterate_obus(data, {false, false}, fn obu_type, {has_seq, has_frame} ->
      case obu_type do
        @obu_sequence_header -> {true, has_frame}
        @obu_frame -> {has_seq, true}
        _ -> {has_seq, has_frame}
      end
    end)
  end

  # Extract the sequence header OBU from data
  defp extract_sequence_header(data) do
    find_obu_by_type(data, @obu_sequence_header)
  end

end
