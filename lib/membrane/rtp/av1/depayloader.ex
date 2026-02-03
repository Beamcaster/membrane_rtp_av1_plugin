defmodule Membrane.RTP.AV1.Depayloader do
  @moduledoc """
  RTP depayloader for AV1 video streams.

  This element reassembles AV1 temporal units from RTP packets according to
  [RFC 9628: RTP Payload Format for AV1](https://datatracker.ietf.org/doc/rfc9628/).

  ## Input/Output

  - **Input**: RTP packets (`Membrane.RTP` format)
  - **Output**: AV1 temporal units (`Membrane.RTP.AV1.Format`)

  ## Features

  - Handles OBU fragmentation via Z/Y bits (RFC 9628 §4.3.2)
  - Properly handles N bit for coded video sequence boundaries (RFC 9628 §4.4)
  - Assembles complete temporal units when marker bit is set (RFC 9628 §4.2)
  - Adds temporal delimiter OBU to output temporal units (AV1 Spec §5.3.1)
  - Caches and manages sequence headers across coded video sequences
  - Handles sequence header changes (resolution/profile changes mid-stream)
  - Compatible with OBS/SVT-AV1 continuous intra refresh streams

  ## Aggregation Header Format (RFC 9628 §4.4)

      0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |Z|Y| W |N|-|-|-|
      +-+-+-+-+-+-+-+-+

  - Z: First OBU element is continuation of previous packet's fragment (RFC 9628 §4.3.2)
  - Y: Last OBU element will continue in next packet (RFC 9628 §4.3.2)
  - W: Number of OBU elements (0 = use length fields, 1-3 = count, last has no length) (RFC 9628 §4.3)
  - N: First packet of a coded video sequence (new sequence header expected) (RFC 9628 §4.4)

  ## Telemetry Events

  This module emits the following telemetry events:

  - `[:membrane_rtp_av1, :depayloader, :temporal_unit_emitted]` - Emitted when a temporal unit is output
  - `[:membrane_rtp_av1, :depayloader, :sequence_header_cached]` - Emitted when sequence header is cached
  - `[:membrane_rtp_av1, :depayloader, :keyframe_requested]` - Emitted when PLI is sent upstream
  - `[:membrane_rtp_av1, :depayloader, :fragment_dropped]` - Emitted when fragment is dropped due to packet loss
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, RTP}
  alias Membrane.AV1, as: Format
  alias Membrane.RTP.AV1.LEB128
  alias Membrane.RTP.AV1.ExWebRTC.Payload

  import Bitwise

  # =============================================================================
  # Telemetry Events
  # =============================================================================

  @telemetry_prefix [:membrane_rtp_av1, :depayloader]

  # =============================================================================
  # OBU Type Constants (AV1 Spec Section 6.2.2)
  # =============================================================================

  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_frame_header 3
  @obu_tile_group 4
  @obu_metadata 5
  @obu_frame 6
  @obu_redundant_frame_header 7
  @obu_tile_list 8
  @obu_padding 15

  # =============================================================================
  # Membrane Pad Definitions
  # =============================================================================

  def_input_pad(:input,
    accepted_format: RTP,
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: Format,
    flow_control: :auto
  )

  def_options(
    max_reorder_buffer: [
      spec: pos_integer(),
      default: 10,
      description: "Maximum packets to buffer for reordering per RTP timestamp"
    ],
    require_sequence_header: [
      spec: boolean(),
      default: true,
      description: """
      When true, cache and prepend sequence headers for AV1 decoder initialization.
      If a frame arrives without a cached sequence header, a keyframe request will be emitted.
      Enable this for decoders that require sequence header initialization (e.g., rav1d).
      """
    ]
  )

  # =============================================================================
  # State Definition
  # =============================================================================

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            current_temporal_unit: binary() | nil,
            current_timestamp: non_neg_integer() | nil,
            current_pts: Membrane.Time.t() | nil,
            current_obu_fragment: binary() | nil,
            max_reorder_buffer: pos_integer(),
            require_sequence_header: boolean(),
            stream_format_sent: boolean(),
            cached_sequence_header: binary() | nil,
            sequence_header_generation: non_neg_integer(),
            waiting_for_keyframe: boolean(),
            waiting_for_sequence_header: boolean(),
            last_n_bit_timestamp: non_neg_integer() | nil,
            frames_since_sequence_header: non_neg_integer(),
            # True after a keyframe (N=1) has been successfully output to decoder
            # Inter frames are dropped until this is true to prevent decoder crashes
            keyframe_established: boolean()
          }

    defstruct [
      # Current temporal unit being assembled (multiple OBUs)
      current_temporal_unit: nil,
      # RTP timestamp of current temporal unit
      current_timestamp: nil,
      # PTS of first packet in current temporal unit
      current_pts: nil,
      # OBU fragment being assembled across packets (Z/Y fragmentation)
      current_obu_fragment: nil,
      # Configuration
      max_reorder_buffer: 10,
      require_sequence_header: true,
      # Stream format tracking
      stream_format_sent: false,
      # Sequence header management
      cached_sequence_header: nil,
      # Incremented each time sequence header changes (for debugging/tracking)
      sequence_header_generation: 0,
      # True when we've requested a keyframe and are waiting for it
      waiting_for_keyframe: false,
      # True when N=1 was seen but sequence header not yet received
      waiting_for_sequence_header: false,
      # Timestamp when we last saw N=1
      last_n_bit_timestamp: nil,
      # Count of frames output since last sequence header (for diagnostics)
      frames_since_sequence_header: 0,
      # True after a keyframe (N=1) has been successfully output to decoder
      # Inter frames are dropped until this is true to prevent decoder crashes
      # from missing reference frames
      keyframe_established: false
    ]
  end

  # =============================================================================
  # Membrane Callbacks
  # =============================================================================

  @impl true
  def handle_init(_ctx, opts) do
    state = %State{
      max_reorder_buffer: opts.max_reorder_buffer,
      require_sequence_header: opts.require_sequence_header
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
    %Buffer{payload: payload, pts: pts, metadata: metadata} = buffer

    # Handle padding-only packets (empty payload)
    if payload == <<>> do
      {[], state}
    else
      marker = get_in(metadata, [:rtp, :marker]) || false
      rtp_timestamp = get_in(metadata, [:rtp, :timestamp]) || 0

      case Payload.parse(payload) do
        {:ok, av1_payload} ->
          do_depayload(state, av1_payload, rtp_timestamp, marker, pts)

        {:error, reason} ->
          Membrane.Logger.warning("""
          Couldn't parse AV1 payload, reason: #{inspect(reason)}.
          Resetting depayloader state.
          Payload (first 32 bytes): #{inspect(binary_part(payload, 0, min(32, byte_size(payload))))}
          """)

          {[], reset_depayloader(state)}
      end
    end
  end

  # =============================================================================
  # Debug Logging
  # =============================================================================

  defp log_packet_debug(state, av1_payload, extracted_obus, timestamp, marker) do
    # Use extracted OBUs for accurate OBU type detection
    obu_types = list_obu_types(extracted_obus)

    Membrane.Logger.debug("""
    RTP packet received:
    - Timestamp: #{timestamp}
    - Marker: #{marker}
    - Z=#{av1_payload.z}, Y=#{av1_payload.y}, W=#{av1_payload.w}, N=#{av1_payload.n}
    - OBU types: #{inspect(obu_types)}
    - Cached seq header: #{state.cached_sequence_header != nil} (gen #{state.sequence_header_generation})
    - Waiting for keyframe: #{state.waiting_for_keyframe}
    - Waiting for seq header: #{state.waiting_for_sequence_header}
    """)
  end

  # List OBU types from extracted OBUs (either list, fragment, or both)
  defp list_obu_types({:obus, obu_list}) do
    Enum.map(obu_list, &get_obu_type_from_binary/1)
    |> Enum.map(&obu_type_name/1)
  end

  defp list_obu_types({:fragment, _binary}) do
    ["FRAGMENT"]
  end

  defp list_obu_types({:obus_and_fragment, obu_list, _fragment}) do
    obu_types =
      Enum.map(obu_list, &get_obu_type_from_binary/1)
      |> Enum.map(&obu_type_name/1)

    obu_types ++ ["FRAGMENT"]
  end

  # Get OBU type from first byte of OBU binary
  defp get_obu_type_from_binary(<<_forbidden::1, obu_type::4, _rest_bits::3, _::binary>>), do: obu_type
  defp get_obu_type_from_binary(_), do: -1

  defp obu_type_name(@obu_sequence_header), do: "SEQUENCE_HEADER"
  defp obu_type_name(@obu_temporal_delimiter), do: "TEMPORAL_DELIMITER"
  defp obu_type_name(@obu_frame_header), do: "FRAME_HEADER"
  defp obu_type_name(@obu_tile_group), do: "TILE_GROUP"
  defp obu_type_name(@obu_metadata), do: "METADATA"
  defp obu_type_name(@obu_frame), do: "FRAME"
  defp obu_type_name(@obu_redundant_frame_header), do: "REDUNDANT_FRAME_HEADER"
  defp obu_type_name(@obu_tile_list), do: "TILE_LIST"
  defp obu_type_name(@obu_padding), do: "PADDING"
  defp obu_type_name(n), do: "TYPE_#{n}"

  # =============================================================================
  # Main Depayloading Logic
  # =============================================================================

  defp do_depayload(state, av1_payload, timestamp, marker, pts) do
    # Step 1: Extract raw OBUs from RTP payload based on W field
    # RFC 9628 §4.3: W determines how OBUs are packed with LEB128 length prefixes
    raw_obus = extract_obus_from_rtp_payload(av1_payload)

    # Debug logging with extracted OBUs (correct types after LEB128 stripping)
    log_packet_debug(state, av1_payload, raw_obus, timestamp, marker)

    # Step 2: Handle N bit (new coded video sequence signal)
    # Per spec section 4.4: N=1 means first packet of coded video sequence
    state = handle_n_bit(state, av1_payload, raw_obus, timestamp)

    # Step 3: Handle OBU fragmentation using Z/Y bits
    # Z=0,Y=0: Complete OBU(s)
    # Z=0,Y=1: First fragment
    # Z=1,Y=0: Last fragment
    # Z=1,Y=1: Middle fragment
    state = handle_obu_fragments(state, av1_payload, raw_obus, timestamp, pts)

    # Step 4: Check if we have a complete temporal unit (marker bit set)
    # Note: we use state.current_pts (captured from first packet) not the passed pts
    maybe_emit_temporal_unit(state, marker)
  end

  # -----------------------------------------------------------------------------
  # W-Field Aware OBU Extraction (RFC 9628 §4.3)
  # -----------------------------------------------------------------------------

  # Extract individual OBUs from RTP payload based on W field
  # Returns:
  #   {:obus, [obu1, obu2, ...]} - Complete OBUs as a list (boundaries preserved)
  #   {:fragment, binary} - Fragment data (partial OBU, Z=1 continuation)
  #   {:obus_and_fragment, [complete_obus], fragment} - Complete OBUs followed by trailing fragment (Y=1)
  #
  # W=0: All OBUs have LEB128 length prefix
  # W=1-3: That many OBUs, all but last have LEB128 length prefix
  #
  # RFC 9628 §4.3.2:
  # - Z=1: First OBU element is continuation of previous packet's fragment
  # - Y=1: Last OBU element will continue in next packet
  # When Y=1, there may be complete OBUs BEFORE the trailing fragment!
  defp extract_obus_from_rtp_payload(%{w: w, z: z, y: y, payload: payload}) do
    result =
      cond do
        # Z=1: This packet starts with a continuation fragment
        # The entire payload (or first OBU element) is fragment data
        z == 1 ->
          {:fragment, payload}

        # Y=1, Z=0: Last OBU continues in next packet, but preceding OBUs are complete
        # We need to extract complete OBUs and identify the trailing fragment
        y == 1 and z == 0 ->
          extract_obus_with_trailing_fragment(payload, w)

        # Z=0, Y=0: All OBUs are complete
        # W=0: Length-prefixed format - all OBUs have LEB128 prefix
        w == 0 ->
          {:obus, extract_length_prefixed_obus(payload, [])}

        # W=1: Single OBU, no length prefix (extends to end of packet)
        w == 1 ->
          {:obus, [payload]}

        # W=2-3: Multiple OBUs, all but last have LEB128 prefix
        w in 2..3 ->
          {:obus, extract_w_obus(payload, w, [])}

        true ->
          # Fallback: treat as single OBU
          {:obus, [payload]}
      end

    # Normalize OBUs to have size fields for proper parsing later
    # This prevents false OBU header detection in analyze_temporal_unit
    normalize_extracted_obus(result)
  end

  # Normalize extracted OBUs to ensure they have size fields
  defp normalize_extracted_obus({:obus, obus}) do
    {:obus, ensure_obus_have_size_fields(obus)}
  end

  defp normalize_extracted_obus({:fragment, fragment}) do
    # Fragments are partial OBUs - we'll normalize when complete
    {:fragment, fragment}
  end

  defp normalize_extracted_obus({:obus_and_fragment, obus, fragment}) do
    {:obus_and_fragment, ensure_obus_have_size_fields(obus), fragment}
  end

  # Extract complete OBUs when Y=1 (last OBU is a fragment)
  # Returns {:obus_and_fragment, [complete_obus], fragment} or {:fragment, binary}
  defp extract_obus_with_trailing_fragment(payload, w) do
    case w do
      # W=0: All OBUs have LEB128 prefix, extract complete ones
      0 ->
        extract_length_prefixed_obus_with_fragment(payload)

      # W=1: Single OBU that's a fragment (no complete OBUs)
      1 ->
        {:fragment, payload}

      # W=2-3: W OBUs total, first W-1 have LEB128 prefix and are complete
      # Last one (no prefix, extends to end) is fragment
      w when w in 2..3 ->
        extract_w_obus_with_fragment(payload, w)

      _ ->
        {:fragment, payload}
    end
  end

  # Extract OBUs in W=0 format when Y=1
  # All complete OBUs have LEB128 prefix, last partial one may not
  defp extract_length_prefixed_obus_with_fragment(payload) do
    {complete_obus, remaining} = extract_complete_length_prefixed_obus(payload, [])

    case {complete_obus, remaining} do
      # No complete OBUs, entire payload is fragment
      {[], _} ->
        {:fragment, payload}

      # Have complete OBUs and remaining fragment
      {obus, <<>>} ->
        # Edge case: no remaining data (shouldn't happen with Y=1 but handle gracefully)
        {:obus, obus}

      {obus, fragment} ->
        {:obus_and_fragment, obus, fragment}
    end
  end

  # Extract complete OBUs until we can't read another complete one
  # Returns {[complete_obus], remaining_binary}
  defp extract_complete_length_prefixed_obus(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp extract_complete_length_prefixed_obus(data, acc) do
    case LEB128.read(data) do
      {:ok, leb_size, obu_length} ->
        <<_leb::binary-size(leb_size), rest::binary>> = data

        if obu_length <= byte_size(rest) do
          # Complete OBU - extract and continue
          <<obu::binary-size(obu_length), remaining::binary>> = rest
          extract_complete_length_prefixed_obus(remaining, [obu | acc])
        else
          # Incomplete OBU - this is the fragment
          # Return accumulated OBUs and the remaining data (including the LEB128 we just read)
          {Enum.reverse(acc), data}
        end

      {:error, _} ->
        # Can't parse LEB128 - remaining data is fragment
        {Enum.reverse(acc), data}
    end
  end

  # Extract OBUs in W=2-3 format when Y=1
  # First W-1 OBUs have LEB128 prefix and are complete, last one is fragment
  defp extract_w_obus_with_fragment(payload, w) do
    {complete_obus, remaining} = extract_w_complete_obus(payload, w - 1, [])

    case {complete_obus, remaining} do
      {[], _} ->
        {:fragment, payload}

      {obus, <<>>} ->
        {:obus, obus}

      {obus, fragment} ->
        {:obus_and_fragment, obus, fragment}
    end
  end

  # Extract exactly count complete OBUs with LEB128 prefix
  defp extract_w_complete_obus(data, 0, acc), do: {Enum.reverse(acc), data}
  defp extract_w_complete_obus(<<>>, _count, acc), do: {Enum.reverse(acc), <<>>}

  defp extract_w_complete_obus(data, count, acc) do
    case LEB128.read(data) do
      {:ok, leb_size, obu_length} ->
        <<_leb::binary-size(leb_size), rest::binary>> = data

        if obu_length <= byte_size(rest) do
          <<obu::binary-size(obu_length), remaining::binary>> = rest
          extract_w_complete_obus(remaining, count - 1, [obu | acc])
        else
          # Truncated - return what we have
          {Enum.reverse(acc), data}
        end

      {:error, _} ->
        {Enum.reverse(acc), data}
    end
  end

  # Extract OBUs in W=0 (length-prefixed) format
  # Each OBU is preceded by LEB128 length
  defp extract_length_prefixed_obus(<<>>, acc), do: Enum.reverse(acc)

  defp extract_length_prefixed_obus(data, acc) do
    case LEB128.read(data) do
      {:ok, leb_size, obu_length} ->
        # Skip past LEB128 bytes and extract OBU
        <<_leb::binary-size(leb_size), rest::binary>> = data

        if obu_length <= byte_size(rest) do
          <<obu::binary-size(obu_length), remaining::binary>> = rest
          extract_length_prefixed_obus(remaining, [obu | acc])
        else
          # Truncated OBU - take what's available
          Enum.reverse([rest | acc])
        end

      {:error, _} ->
        # Can't parse LEB128 - return accumulated OBUs
        Enum.reverse(acc)
    end
  end

  # Extract OBUs in W=2-3 format
  # All but last OBU have LEB128 length prefix
  defp extract_w_obus(data, remaining_count, acc) when remaining_count <= 1 do
    # Last OBU has no length prefix - extends to end of packet
    Enum.reverse([data | acc])
  end

  defp extract_w_obus(<<>>, _remaining_count, acc), do: Enum.reverse(acc)

  defp extract_w_obus(data, remaining_count, acc) do
    case LEB128.read(data) do
      {:ok, leb_size, obu_length} ->
        <<_leb::binary-size(leb_size), rest::binary>> = data

        if obu_length <= byte_size(rest) do
          <<obu::binary-size(obu_length), remaining::binary>> = rest
          extract_w_obus(remaining, remaining_count - 1, [obu | acc])
        else
          # Truncated - take remaining as last OBU
          Enum.reverse([rest | acc])
        end

      {:error, _} ->
        # Can't parse - treat remainder as last OBU
        Enum.reverse([data | acc])
    end
  end

  # -----------------------------------------------------------------------------
  # N Bit Handling (Coded Video Sequence Boundaries)
  # -----------------------------------------------------------------------------

  defp handle_n_bit(state, %{n: 1}, extracted_obus, timestamp) do
    # N=1 indicates first packet of a new coded video sequence
    # Per spec: "MUST be set to 1 if the packet is the first packet of a coded video sequence"
    # A sequence header SHOULD be present in this temporal unit

    Membrane.Logger.debug("N=1: New coded video sequence starting at timestamp #{timestamp}")

    # Extract sequence header based on format
    # For {:obus_and_fragment, ...}, check the complete OBUs for sequence header
    seq_header =
      case extracted_obus do
        {:obus, obu_list} -> find_sequence_header_in_list(obu_list)
        {:obus_and_fragment, obu_list, _fragment} -> find_sequence_header_in_list(obu_list)
        {:fragment, _binary} -> nil
      end

    case seq_header do
      nil ->
        # Sequence header not in this packet - might be in next packet of same TU
        # Or encoder might be sending it separately (less common)
        Membrane.Logger.debug(
          "N=1 packet without sequence header - may arrive in subsequent packet"
        )

        %{state | waiting_for_sequence_header: true, last_n_bit_timestamp: timestamp}

      seq_header ->
        handle_sequence_header_received(state, seq_header, timestamp)
    end
  end

  defp handle_n_bit(state, _av1_payload, _extracted_obus, _timestamp), do: state

  # Find sequence header in list of OBUs by checking OBU type byte
  # OBU header: 0|type(4)|extension(1)|has_size(1)|reserved(1)
  # Sequence header type = 1
  defp find_sequence_header_in_list([]), do: nil

  defp find_sequence_header_in_list([obu | rest]) do
    case obu do
      <<_forbidden::1, @obu_sequence_header::4, _rest_bits::3, _::binary>> ->
        obu

      _ ->
        find_sequence_header_in_list(rest)
    end
  end

  defp handle_sequence_header_received(state, new_seq_header, timestamp) do
    cond do
      # First sequence header ever
      state.cached_sequence_header == nil ->
        Membrane.Logger.debug("""
        Initial sequence header received and cached
        - Size: #{byte_size(new_seq_header)} bytes
        - Timestamp: #{timestamp}
        """)

        emit_sequence_header_telemetry(1, byte_size(new_seq_header), :initial)

        %{
          state
          | cached_sequence_header: new_seq_header,
            sequence_header_generation: 1,
            waiting_for_keyframe: false,
            waiting_for_sequence_header: false,
            last_n_bit_timestamp: timestamp,
            frames_since_sequence_header: 0
        }

      # Sequence header changed (resolution change, profile change, etc.)
      new_seq_header != state.cached_sequence_header ->
        new_generation = state.sequence_header_generation + 1

        Membrane.Logger.debug("""
        Sequence header CHANGED - new coded video sequence
        - Previous size: #{byte_size(state.cached_sequence_header)} bytes
        - New size: #{byte_size(new_seq_header)} bytes
        - Generation: #{state.sequence_header_generation} -> #{new_generation}
        - Frames since last seq header: #{state.frames_since_sequence_header}
        Note: Decoder may need reinitialization
        """)

        emit_sequence_header_telemetry(new_generation, byte_size(new_seq_header), :changed)

        %{
          state
          | cached_sequence_header: new_seq_header,
            sequence_header_generation: new_generation,
            waiting_for_keyframe: false,
            waiting_for_sequence_header: false,
            last_n_bit_timestamp: timestamp,
            frames_since_sequence_header: 0
        }

      # Same sequence header (common case - keyframe with same params)
      true ->
        Membrane.Logger.debug(
          "Sequence header unchanged (generation #{state.sequence_header_generation})"
        )

        %{
          state
          | waiting_for_keyframe: false,
            waiting_for_sequence_header: false,
            last_n_bit_timestamp: timestamp,
            frames_since_sequence_header: 0
        }
    end
  end

  defp emit_sequence_header_telemetry(generation, size, reason) do
    :telemetry.execute(
      @telemetry_prefix ++ [:sequence_header_cached],
      %{generation: generation, size: size},
      %{reason: reason}
    )
  end

  # -----------------------------------------------------------------------------
  # OBU Fragment Handling (Z/Y Bits)
  # -----------------------------------------------------------------------------

  # extracted_obus: {:obus, [list]}, {:fragment, binary}, or {:obus_and_fragment, [list], binary}
  defp handle_obu_fragments(state, av1_payload, extracted_obus, timestamp, pts) do
    case {av1_payload.z, av1_payload.y, state.current_obu_fragment} do
      # Z=0, Y=0: Single complete OBU (or multiple complete OBUs)
      {0, 0, nil} ->
        append_obus(state, timestamp, extracted_obus, pts)

      # Z=0, Y=0: Complete OBU but we have leftover fragment (packet loss case)
      {0, 0, _fragment} ->
        Membrane.Logger.debug(
          "Received complete OBU while having incomplete fragment - dropping fragment (likely packet loss)"
        )

        emit_fragment_dropped_telemetry(:incomplete_fragment_replaced, 0, 0)

        # Packet loss detected - reset keyframe state as decoder references may be stale
        state
        |> handle_packet_loss()
        |> reset_obu_fragment()
        |> append_obus(timestamp, extracted_obus, pts)

      # Z=0, Y=1: First fragment of an OBU (possibly with complete OBUs before it)
      {0, 1, nil} ->
        handle_y1_packet(state, extracted_obus, timestamp, pts)

      # Z=0, Y=1: First fragment but we already have one (packet loss case)
      {0, 1, _fragment} ->
        Membrane.Logger.debug(
          "Received first OBU fragment while having incomplete fragment - dropping old fragment"
        )

        emit_fragment_dropped_telemetry(:new_fragment_started, 0, 1)

        # Packet loss detected - reset keyframe state
        state
        |> handle_packet_loss()
        |> reset_obu_fragment()
        |> handle_y1_packet(extracted_obus, timestamp, pts)

      # Z=1, Y=0: Last fragment of an OBU
      {1, 0, fragment} when fragment != nil and timestamp == state.current_timestamp ->
        {:fragment, fragment_data} = extracted_obus
        complete_obu = fragment <> fragment_data
        # Normalize the reassembled OBU to ensure it has a size field
        normalized_obu = ensure_obu_has_size_field(complete_obu)

        state
        |> reset_obu_fragment()
        # Use existing current_pts since this is a continuation (not first packet)
        # Wrap in list for append_obus
        |> append_obus(timestamp, {:obus, [normalized_obu]}, state.current_pts)

      # Z=1, Y=0: Last fragment but no matching first fragment
      {1, 0, _} ->
        Membrane.Logger.warning(
          "Received last OBU fragment without matching first fragment - dropping (packet loss)"
        )

        emit_fragment_dropped_telemetry(:no_matching_first, 1, 0)

        # Packet loss detected - reset keyframe state
        state
        |> handle_packet_loss()
        |> reset_obu_fragment()

      # Z=1, Y=1: Middle fragment of an OBU
      {1, 1, fragment} when fragment != nil and timestamp == state.current_timestamp ->
        {:fragment, fragment_data} = extracted_obus
        %{state | current_obu_fragment: fragment <> fragment_data}

      # Z=1, Y=1: Middle fragment but no matching first fragment
      {1, 1, _} ->
        Membrane.Logger.debug(
          "Received middle OBU fragment without matching first fragment - dropping (packet loss)"
        )

        emit_fragment_dropped_telemetry(:no_matching_first, 1, 1)

        # Packet loss detected - reset keyframe state
        state
        |> handle_packet_loss()
        |> reset_obu_fragment()
    end
  end

  # Handle packet loss by resetting keyframe state
  # This ensures decoder won't receive inter frames with stale references
  defp handle_packet_loss(state) do
    if state.keyframe_established do
      Membrane.Logger.warning("""
      Packet loss detected - resetting keyframe state
      Decoder will wait for next keyframe before accepting inter frames
      """)

      %{state | keyframe_established: false, waiting_for_keyframe: true}
    else
      state
    end
  end

  # Handle Y=1 packets which may have complete OBUs followed by a trailing fragment
  defp handle_y1_packet(state, {:fragment, fragment_data}, timestamp, pts) do
    # Pure fragment - no complete OBUs
    start_obu_fragment(state, timestamp, fragment_data, pts)
  end

  defp handle_y1_packet(state, {:obus_and_fragment, obu_list, fragment_data}, timestamp, pts) do
    # Complete OBUs followed by a fragment
    # First, append the complete OBUs to the temporal unit
    state = append_obus(state, timestamp, {:obus, obu_list}, pts)
    # Then, start the fragment
    start_obu_fragment(state, timestamp, fragment_data, pts)
  end

  defp handle_y1_packet(state, {:obus, obu_list}, timestamp, pts) do
    # Edge case: Y=1 but all OBUs turned out to be complete (shouldn't happen but handle gracefully)
    append_obus(state, timestamp, {:obus, obu_list}, pts)
  end

  defp emit_fragment_dropped_telemetry(reason, z, y) do
    :telemetry.execute(
      @telemetry_prefix ++ [:fragment_dropped],
      %{count: 1},
      %{reason: reason, z_bit: z, y_bit: y}
    )
  end

  defp start_obu_fragment(state, timestamp, fragment, pts) do
    if state.current_temporal_unit != nil and timestamp != state.current_timestamp do
      Membrane.Logger.debug("""
      Starting OBU fragment with different timestamp - dropping incomplete temporal unit
      Old timestamp: #{state.current_timestamp}, New timestamp: #{timestamp}
      """)
    end

    # When starting a new temporal unit (different timestamp), capture PTS
    new_pts = if timestamp != state.current_timestamp, do: pts, else: state.current_pts

    %{
      state
      | current_obu_fragment: fragment,
        current_timestamp: timestamp,
        current_pts: new_pts,
        current_temporal_unit:
          if(timestamp != state.current_timestamp, do: nil, else: state.current_temporal_unit)
    }
  end

  defp reset_obu_fragment(state) do
    %{state | current_obu_fragment: nil}
  end

  # -----------------------------------------------------------------------------
  # OBU Accumulation
  # -----------------------------------------------------------------------------

  # Handle {:obus_and_fragment, ...} by extracting just the complete OBUs
  # This is a defensive clause - normally handle_y1_packet processes this format
  defp append_obus(state, timestamp, {:obus_and_fragment, obu_list, _fragment}, pts) do
    append_obus(state, timestamp, {:obus, obu_list}, pts)
  end

  # Handle {:obus, list} format - filter and concatenate
  defp append_obus(state, timestamp, {:obus, obu_list}, pts) do
    # Strip temporal delimiters - we add a canonical one at output
    # Also strip tile list OBUs per spec: "SHOULD be removed when transmitted"
    filtered_list = strip_unwanted_obus_from_list(obu_list)

    if filtered_list == [] do
      state
    else
      # Concatenate filtered OBUs into binary
      filtered_data = IO.iodata_to_binary(filtered_list)

      # Check for sequence header in the OBUs (may arrive without N=1 in some edge cases)
      state = maybe_cache_sequence_header_opportunistic(state, filtered_list, timestamp)

      cond do
        # Starting new temporal unit - capture PTS from first packet
        state.current_temporal_unit == nil ->
          %{
            state
            | current_temporal_unit: filtered_data,
              current_timestamp: timestamp,
              current_pts: pts
          }

        # Different timestamp - new temporal unit (previous one incomplete)
        timestamp != state.current_timestamp ->
          Membrane.Logger.warning("""
          Received OBU with different timestamp without finishing previous temporal unit
          Old timestamp: #{state.current_timestamp}, New timestamp: #{timestamp}
          Dropping incomplete temporal unit
          """)

          %{
            state
            | current_temporal_unit: filtered_data,
              current_timestamp: timestamp,
              current_pts: pts
          }

        # Same timestamp - append to current temporal unit (keep existing PTS)
        true ->
          %{state | current_temporal_unit: state.current_temporal_unit <> filtered_data}
      end
    end
  end

  # Filter unwanted OBUs from list by checking type byte
  defp strip_unwanted_obus_from_list(obu_list) do
    Enum.reject(obu_list, fn obu ->
      case obu do
        <<_forbidden::1, obu_type::4, _rest::3, _::binary>> ->
          obu_type in [@obu_temporal_delimiter, @obu_tile_list]

        _ ->
          false
      end
    end)
  end

  # Opportunistically cache sequence header even if N bit wasn't set
  # This handles edge cases where sequence header arrives mid-stream
  # Accepts list of OBUs
  defp maybe_cache_sequence_header_opportunistic(state, obu_list, timestamp)
       when is_list(obu_list) do
    if state.require_sequence_header do
      case find_sequence_header_in_list(obu_list) do
        nil ->
          state

        seq_header when state.waiting_for_sequence_header ->
          # We were expecting this after N=1
          Membrane.Logger.debug("Found sequence header after N=1 (in subsequent packet)")
          handle_sequence_header_received(state, seq_header, timestamp)

        seq_header when state.cached_sequence_header == nil ->
          # First sequence header (even without N=1)
          Membrane.Logger.debug("Found sequence header without N=1 - caching opportunistically")
          handle_sequence_header_received(state, seq_header, timestamp)

        seq_header when seq_header != state.cached_sequence_header ->
          # Sequence header changed without N=1 (unusual but handle it)
          Membrane.Logger.warning("""
          Sequence header changed WITHOUT N=1 bit set - this is unusual
          Caching new sequence header anyway
          """)

          handle_sequence_header_received(state, seq_header, timestamp)

        _seq_header ->
          # Same sequence header, no change needed
          state
      end
    else
      state
    end
  end

  # -----------------------------------------------------------------------------
  # Temporal Unit Emission
  # -----------------------------------------------------------------------------

  defp maybe_emit_temporal_unit(state, marker) do
    case {state.current_temporal_unit, marker} do
      {nil, _} ->
        {[], state}

      {temporal_unit, true} ->
        # Marker bit set - temporal unit is complete
        # Use state.current_pts which was captured from the first packet of this temporal unit
        emit_temporal_unit(state, temporal_unit, state.current_pts)

      {_temporal_unit, false} ->
        # More packets expected for this temporal unit
        {[], state}
    end
  end

  defp emit_temporal_unit(state, temporal_unit, pts) do
    # Build the complete temporal unit with proper OBU ordering:
    # 1. Temporal Delimiter (required by some decoders)
    # 2. Sequence Header (if needed)
    # 3. Frame data

    {actions, new_state} = build_output(temporal_unit, pts, state)
    {actions, reset_depayloader(new_state)}
  end

  defp build_output(temporal_unit, pts, state) do
    # Send stream format on first output if not already sent
    format_actions =
      if not state.stream_format_sent do
        [stream_format: {:output, %Format{}}]
      else
        []
      end

    # Build output with proper sequence header handling
    {buffer_actions, new_state} = build_output_with_sequence_header(temporal_unit, pts, state)

    # Emit telemetry for temporal unit emission
    analysis = analyze_temporal_unit(temporal_unit)
    emit_temporal_unit_telemetry(temporal_unit, analysis)

    new_state = %{
      new_state
      | stream_format_sent: true,
        frames_since_sequence_header: new_state.frames_since_sequence_header + 1
    }

    {format_actions ++ buffer_actions, new_state}
  end

  defp emit_temporal_unit_telemetry(temporal_unit, analysis) do
    :telemetry.execute(
      @telemetry_prefix ++ [:temporal_unit_emitted],
      %{
        size: byte_size(temporal_unit),
        has_sequence_header: analysis.sequence_header != nil,
        has_frame: analysis.has_frame,
        has_frame_header: analysis.has_frame_header,
        has_tile_group: analysis.has_tile_group
      },
      %{}
    )
  end

  defp build_output_with_sequence_header(temporal_unit, pts, state) do
    if not state.require_sequence_header do
      # Sequence header management disabled - output as-is with temporal delimiter
      output = prepend_temporal_delimiter(temporal_unit)
      is_keyframe = contains_sequence_header?(temporal_unit)
      buffer = build_buffer(output, pts, is_keyframe)
      {[buffer: {:output, buffer}], state}
    else
      build_output_with_managed_sequence_header(temporal_unit, pts, state)
    end
  end

  defp build_output_with_managed_sequence_header(temporal_unit, pts, state) do
    # Analyze what's in this temporal unit
    analysis = analyze_temporal_unit(temporal_unit)

    # Update state with any sequence header found
    state =
      if analysis.sequence_header != nil and
           (state.cached_sequence_header == nil or
              analysis.sequence_header != state.cached_sequence_header) do
        Membrane.Logger.info("Updating cached sequence header from temporal unit content")
        handle_sequence_header_received(state, analysis.sequence_header, state.current_timestamp)
      else
        state
      end

    # Frame data can be either OBU_FRAME or separate OBU_FRAME_HEADER + OBU_TILE_GROUP
    # OBS/SVT-AV1 may use either format depending on encoding settings
    has_frame_data =
      analysis.has_frame or (analysis.has_frame_header and analysis.has_tile_group)

    # Check if this is a keyframe (contains sequence header - indicates N=1 coded video sequence start)
    is_keyframe = analysis.sequence_header != nil

    cond do
      # No cached sequence header and we have frame data - can't decode, request keyframe
      state.cached_sequence_header == nil and has_frame_data ->
        Membrane.Logger.warning("""
        Cannot output frame - no sequence header available
        Requesting keyframe (PLI) via upstream event to get sequence header for decoder initialization
        """)

        # Emit telemetry for keyframe request
        emit_keyframe_requested_telemetry(:no_sequence_header)

        # Send KeyframeRequestEvent to :input pad to propagate UPSTREAM toward the source
        # This will eventually reach RTPSource which sends PLI to the WebRTC peer
        {[event: {:input, %Membrane.KeyframeRequestEvent{}}],
         %{state | waiting_for_keyframe: true}}

      # CRITICAL: Inter frame arrived before any keyframe was established
      # Decoder has no reference frames yet - outputting would crash decoder
      # This catches the case where we have cached seq header from a previous
      # session but decoder was reset/restarted
      not state.keyframe_established and not is_keyframe and has_frame_data ->
        Membrane.Logger.warning("""
        Dropping inter frame - no keyframe has been established yet
        Decoder needs a keyframe first to initialize reference frames
        Requesting keyframe (PLI)
        """)

        emit_keyframe_requested_telemetry(:no_keyframe_established)

        {[event: {:input, %Membrane.KeyframeRequestEvent{}}],
         %{state | waiting_for_keyframe: true}}

      # Keyframe (has sequence header) - output and mark keyframe as established
      is_keyframe and has_frame_data ->
        output = prepend_temporal_delimiter(temporal_unit)
        buffer = build_buffer(output, pts, true)

        Membrane.Logger.debug("Keyframe output - decoder reference frames will be established")

        {[buffer: {:output, buffer}],
         %{state | keyframe_established: true, waiting_for_keyframe: false}}

      # Have cached sequence header, keyframe established, but this frame doesn't include seq header - prepend it
      state.cached_sequence_header != nil and
        state.keyframe_established and
        analysis.sequence_header == nil and
          has_frame_data ->
        output =
          build_complete_temporal_unit(
            state.cached_sequence_header,
            temporal_unit
          )

        buffer = build_buffer(output, pts, false)
        {[buffer: {:output, buffer}], state}

      # Temporal unit already has sequence header or no frame data
      true ->
        output = prepend_temporal_delimiter(temporal_unit)
        buffer = build_buffer(output, pts, is_keyframe)
        {[buffer: {:output, buffer}], state}
    end
  end

  defp emit_keyframe_requested_telemetry(reason) do
    :telemetry.execute(
      @telemetry_prefix ++ [:keyframe_requested],
      %{count: 1},
      %{reason: reason}
    )
  end

  defp build_buffer(payload, pts, key_frame?) do
    %Buffer{
      payload: payload,
      pts: pts,
      metadata: %{
        av1: %{
          temporal_unit_size: byte_size(payload),
          key_frame?: key_frame?
        }
      }
    }
  end

  # Build complete temporal unit: TD + Sequence Header + Frame Data
  defp build_complete_temporal_unit(sequence_header, frame_data) do
    temporal_delimiter = create_temporal_delimiter()
    temporal_delimiter <> sequence_header <> frame_data
  end

  defp prepend_temporal_delimiter(data) do
    create_temporal_delimiter() <> data
  end

  # Creates a canonical temporal delimiter OBU
  # Format per AV1 spec section 5.3.1:
  # - obu_forbidden_bit = 0 (1 bit)
  # - obu_type = 2 (4 bits)
  # - obu_extension_flag = 0 (1 bit)
  # - obu_has_size_field = 1 (1 bit)
  # - obu_reserved_1bit = 0 (1 bit)
  # - obu_size = 0 (LEB128, 1 byte for value 0)
  defp create_temporal_delimiter do
    # Header byte: 0_0010_0_1_0 = 0x12
    # Size byte: 0 (LEB128 encoding of 0)
    <<0x12, 0x00>>
  end

  # -----------------------------------------------------------------------------
  # State Reset
  # -----------------------------------------------------------------------------

  defp reset_depayloader(state) do
    %{
      state
      | current_temporal_unit: nil,
        current_timestamp: nil,
        current_pts: nil,
        current_obu_fragment: nil
    }
  end

  # =============================================================================
  # OBU Parsing Utilities
  # =============================================================================

  @doc false
  # Parse OBU header and return structured information
  # Returns {:ok, info} or {:error, reason}
  def parse_obu_header(<<header::8, rest::binary>>) do
    # OBU header format (section 5.3.1):
    # - obu_forbidden_bit (1 bit) - must be 0
    # - obu_type (4 bits)
    # - obu_extension_flag (1 bit)
    # - obu_has_size_field (1 bit)
    # - obu_reserved_1bit (1 bit)

    forbidden_bit = header >>> 7
    obu_type = header >>> 3 &&& 0x0F
    has_extension = (header &&& 0x04) != 0
    has_size = (header &&& 0x02) != 0

    if forbidden_bit != 0 do
      {:error, :forbidden_bit_set}
    else
      # Handle extension header if present
      {rest_after_ext, extension_bytes, extension_header} =
        if has_extension do
          case rest do
            <<ext_header::8, r::binary>> ->
              temporal_id = ext_header >>> 5 &&& 0x07
              spatial_id = ext_header >>> 3 &&& 0x03
              {r, 1, %{temporal_id: temporal_id, spatial_id: spatial_id}}

            _ ->
              {rest, 0, nil}
          end
        else
          {rest, 0, nil}
        end

      {:ok,
       %{
         type: obu_type,
         has_size: has_size,
         has_extension: has_extension,
         extension: extension_header,
         header_bytes: 1 + extension_bytes,
         rest: rest_after_ext
       }}
    end
  end

  def parse_obu_header(<<>>), do: {:error, :empty_data}
  def parse_obu_header(_), do: {:error, :invalid_data}

  # -----------------------------------------------------------------------------
  # OBU Size Field Normalization
  # -----------------------------------------------------------------------------

  # Ensures an OBU has the obu_has_size_field set and includes a proper LEB128 size.
  # This is critical for correct parsing when OBUs are concatenated into temporal units.
  #
  # GStreamer sends OBUs without size fields (obu_has_size_field=0), which is valid
  # per RFC 9628. However, when these OBUs are concatenated, we lose boundary info
  # and the heuristic boundary scanning in analyze_temporal_unit can find false OBU
  # headers in frame data.
  #
  # By adding size fields during extraction, we ensure proper parsing later.
  defp ensure_obu_has_size_field(obu) when byte_size(obu) < 1, do: obu

  defp ensure_obu_has_size_field(<<header::8, rest::binary>> = obu) do
    has_extension = (header &&& 0x04) != 0
    has_size = (header &&& 0x02) != 0

    if has_size do
      # Already has size field, return as-is
      obu
    else
      # Need to add size field
      # Calculate payload size (everything after header and optional extension)
      {payload, ext_byte} =
        if has_extension and byte_size(rest) >= 1 do
          <<ext::binary-size(1), payload::binary>> = rest
          {payload, ext}
        else
          {rest, <<>>}
        end

      payload_size = byte_size(payload)
      size_leb = LEB128.encode(payload_size)

      # Set the has_size bit (bit 1) in the header
      new_header = header ||| 0x02

      # Reconstruct OBU: header + extension (if any) + size + payload
      <<new_header, ext_byte::binary, size_leb::binary, payload::binary>>
    end
  end

  defp ensure_obu_has_size_field(obu), do: obu

  # Apply size field normalization to a list of OBUs
  defp ensure_obus_have_size_fields(obus) when is_list(obus) do
    Enum.map(obus, &ensure_obu_has_size_field/1)
  end

  # Read OBU size using LEB128 encoding
  defp read_obu_size(data) do
    case LEB128.read(data) do
      {:ok, size_bytes, value} -> {:ok, value, size_bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  # Get total OBU size (header + size field + payload)
  defp get_obu_total_size(data) do
    case parse_obu_header(data) do
      {:ok, obu_info} ->
        if obu_info.has_size do
          case read_obu_size(obu_info.rest) do
            {:ok, payload_size, size_bytes} ->
              {:ok, obu_info.header_bytes + size_bytes + payload_size}

            {:error, _} = err ->
              err
          end
        else
          # OBU without size field - special handling needed
          get_obu_size_without_field(obu_info, data)
        end

      {:error, _} = err ->
        err
    end
  end

  # Handle OBUs without size field
  # Per RTP spec: "obu_has_size_field flag SHOULD be set to zero in all OBUs"
  # For these, we need context about what type of OBU it is
  defp get_obu_size_without_field(obu_info, full_data) do
    case obu_info.type do
      # Temporal delimiter has no payload
      @obu_temporal_delimiter ->
        {:ok, obu_info.header_bytes}

      # For other types, try to find next OBU boundary
      # This is heuristic and works when OBUs are back-to-back
      _ ->
        case find_next_obu_boundary(full_data, obu_info.header_bytes) do
          {:found, offset} -> {:ok, offset}
          :not_found -> {:ok, byte_size(full_data)}
        end
    end
  end

  # Find the next OBU boundary by scanning for valid OBU headers
  defp find_next_obu_boundary(data, start_offset) do
    scan_for_obu_boundary(data, start_offset)
  end

  defp scan_for_obu_boundary(data, offset) when offset >= byte_size(data) do
    :not_found
  end

  defp scan_for_obu_boundary(data, offset) do
    <<_::binary-size(offset), rest::binary>> = data

    case rest do
      <<header::8, _::binary>> ->
        forbidden_bit = header >>> 7
        obu_type = header >>> 3 &&& 0x0F

        # Valid OBU: forbidden bit = 0, type in valid range
        if (forbidden_bit == 0 and obu_type in 1..8) or obu_type == 15 do
          {:found, offset}
        else
          scan_for_obu_boundary(data, offset + 1)
        end

      _ ->
        :not_found
    end
  end

  # Quick check if temporal unit contains a sequence header (indicates keyframe)
  defp contains_sequence_header?(data) do
    analyze_temporal_unit(data).sequence_header != nil
  end

  # Analyze temporal unit for presence of key OBU types
  defp analyze_temporal_unit(data) do
    initial = %{
      has_frame: false,
      has_frame_header: false,
      has_tile_group: false,
      has_metadata: false,
      sequence_header: nil
    }

    iterate_obus_with_data(data, initial, fn obu_type, obu_data, acc ->
      case obu_type do
        @obu_sequence_header ->
          %{acc | sequence_header: obu_data}

        @obu_frame ->
          %{acc | has_frame: true}

        @obu_frame_header ->
          %{acc | has_frame_header: true}

        @obu_tile_group ->
          %{acc | has_tile_group: true}

        @obu_metadata ->
          %{acc | has_metadata: true}

        _ ->
          acc
      end
    end)
  end

  # Like iterate_obus but passes both type and full OBU data to callback
  defp iterate_obus_with_data(data, acc, fun), do: iterate_obus_with_data_impl(data, acc, fun)

  defp iterate_obus_with_data_impl(<<>>, acc, _fun), do: acc

  defp iterate_obus_with_data_impl(data, acc, fun) do
    case get_obu_total_size(data) do
      {:ok, total_size} when total_size > 0 and total_size <= byte_size(data) ->
        <<obu_data::binary-size(total_size), rest::binary>> = data

        case parse_obu_header(obu_data) do
          {:ok, obu_info} ->
            acc = fun.(obu_info.type, obu_data, acc)
            iterate_obus_with_data_impl(rest, acc, fun)

          {:error, _} ->
            acc
        end

      _ ->
        acc
    end
  end
end
