defmodule Membrane.RTP.AV1.Depayloader do
  @moduledoc """
  RTP depayloader for AV1.

  Minimal implementation that:
  - Reassembles access units by concatenating RTP payloads until marker bit
  - Emits one AV1 access unit per output buffer

  Extend to parse AV1 RTP headers, handle OBU aggregation, and scalability signaling.
  """
  use Membrane.Filter

  alias Membrane.Buffer

  alias Membrane.RTP.AV1.{
    Header,
    SequenceTracker,
    SpecHeader,
    WBitStateMachine,
    FullHeader,
    Format
  }

  def_input_pad(:input,
    accepted_format: Membrane.RTP
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: Format
  )

  def_options(
    clock_rate: [
      spec: pos_integer(),
      default: 90_000,
      description: "RTP clock rate used for timestamping"
    ],
    fmtp: [
      spec: map(),
      default: %{},
      description: "SDP fmtp parameters map (e.g., cm, tid, lid)"
    ],
    header_mode: [
      spec: atom(),
      default: :draft,
      description: "Header encoding mode for AV1 RTP payloads"
    ],
    max_temporal_id: [
      spec: 0..7 | nil,
      default: nil,
      description:
        "Maximum temporal_id to accept. Packets with higher temporal_id will be filtered. nil = no filtering"
    ],
    max_spatial_id: [
      spec: 0..3 | nil,
      default: nil,
      description:
        "Maximum spatial_id to accept. Packets with higher spatial_id will be filtered. nil = no filtering"
    ],
    per_layer_output: [
      spec: boolean(),
      default: false,
      description:
        "Enable per-layer output mode. When true, creates separate output pads (:output with layer ID) for each temporal layer. When false (default), all layers are emitted on single :output pad. Note: per_layer_output mode is NOT compatible with Membrane.RTP.DepayloaderBin - use the depayloader directly in your pipeline for this advanced feature."
    ],
    fragment_timeout_ms: [
      spec: pos_integer(),
      default: 500,
      description:
        "Timeout in milliseconds for incomplete fragment reassembly. If a fragment is not completed within this time, it will be discarded and a discontinuity event will be emitted."
    ],
    max_access_unit_size: [
      spec: pos_integer(),
      default: 10_000_000,
      description:
        "Maximum size in bytes for an access unit accumulator before forced flush. Prevents memory exhaustion from missing marker bits. Default: 10MB"
    ],
    max_fragment_size: [
      spec: pos_integer(),
      default: 1_000_000,
      description:
        "Maximum size in bytes for a fragment accumulator before reset. Prevents memory exhaustion from incomplete fragments. Default: 1MB"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    opts_map =
      cond do
        is_struct(opts) -> Map.from_struct(opts)
        is_map(opts) -> opts
        true -> Map.new(opts)
      end

    state =
      opts_map
      # Zero-copy optimization: Use IO lists for buffer accumulation instead of binary concatenation
      # IO lists avoid intermediate copies and are flattened only when emitting final buffers
      |> Map.put(:acc, [])
      |> Map.put(:frag_acc, [])
      |> Map.put(:first_pts, nil)
      |> Map.put(:w_state_machine, WBitStateMachine.new())
      |> Map.put(:seq_tracker, SequenceTracker.new())
      |> Map.put(:cached_ss, nil)
      |> Map.put(:discovered_layers, MapSet.new())
      |> Map.put(:fragment_timer_ref, nil)
      |> Map.put(:fragment_start_time, nil)

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    # Send stream format to output pad (required by Membrane before sending buffers)
    stream_format = %Format{
      encoding: "AV1",
      clock_rate: Map.get(state, :clock_rate, 90_000)
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _id) = pad, _ctx, state) do
    require Membrane.Logger

    Membrane.Logger.debug("Output pad #{inspect(pad)} added for per-layer output")

    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload, pts: pts, metadata: metadata}, _ctx, state) do
    marker = get_in(metadata, [:rtp, :marker]) || false
    seq_num = get_in(metadata, [:rtp, :sequence_number])
    first_pts = state.first_pts || pts

    # Validate sequence number if present
    seq_tracker = Map.get(state, :seq_tracker, SequenceTracker.new())
    w_sm = Map.get(state, :w_state_machine, WBitStateMachine.new())

    {seq_tracker, seq_valid?, w_sm, should_reset_fragments?} =
      if seq_num != nil do
        case SequenceTracker.next(seq_tracker, seq_num) do
          {:ok, new_tracker} ->
            # Check if there's a gap during fragment assembly (even small gaps matter)
            gap = SequenceTracker.gap_size(seq_tracker, seq_num)
            in_fragment? = WBitStateMachine.incomplete_fragment?(w_sm)

            if gap > 0 and in_fragment? do
              require Membrane.Logger

              Membrane.Logger.warning(
                "Sequence gap of #{gap} packets detected during fragment assembly " <>
                  "(between #{seq_tracker.last_seq} and #{seq_num}). " <>
                  "Discarding incomplete fragments and resetting state."
              )

              # Emit discontinuity event
              :telemetry.execute(
                [:membrane_rtp_av1, :depayloader, :discontinuity],
                %{gap_size: gap},
                %{reason: :sequence_gap_during_fragmentation}
              )

              # Reset W-bit state machine and indicate fragments should be discarded
              new_w_sm = WBitStateMachine.reset(w_sm)
              {new_tracker, true, new_w_sm, true}
            else
              {new_tracker, true, w_sm, false}
            end

          {:error, :duplicate, tracker} ->
            require Membrane.Logger

            Membrane.Logger.warning(
              "Duplicate RTP packet detected: sequence_number=#{seq_num}. " <>
                "Expected #{SequenceTracker.expected_next(tracker)}. Discarding packet."
            )

            {tracker, false, w_sm, false}

          {:error, :out_of_order, tracker} ->
            require Membrane.Logger

            Membrane.Logger.warning(
              "Out-of-order RTP packet detected: sequence_number=#{seq_num}. " <>
                "Expected #{SequenceTracker.expected_next(tracker)}. Discarding packet."
            )

            {tracker, false, w_sm, false}

          {:error, :large_gap, tracker} ->
            require Membrane.Logger
            gap = SequenceTracker.gap_size(tracker, seq_num)

            # Check if we're in the middle of fragment assembly
            in_fragment? = WBitStateMachine.incomplete_fragment?(w_sm)

            if in_fragment? do
              Membrane.Logger.warning(
                "Sequence gap of #{gap} packets detected during fragment assembly " <>
                  "(between #{tracker.last_seq} and #{seq_num}). " <>
                  "Discarding incomplete fragments and resetting state."
              )

              # Emit discontinuity event
              :telemetry.execute(
                [:membrane_rtp_av1, :depayloader, :discontinuity],
                %{gap_size: gap},
                %{reason: :sequence_gap_during_fragmentation}
              )

              # Reset W-bit state machine and indicate fragments should be discarded
              new_w_sm = WBitStateMachine.reset(w_sm)
              {:ok, new_tracker} = SequenceTracker.next(SequenceTracker.reset(tracker), seq_num)
              {new_tracker, true, new_w_sm, true}
            else
              Membrane.Logger.warning(
                "Large sequence number gap detected: #{gap} packets missing between " <>
                  "#{tracker.last_seq} and #{seq_num}. Accepting packet but data may be incomplete."
              )

              # Accept the packet but log the gap
              {:ok, new_tracker} = SequenceTracker.next(SequenceTracker.reset(tracker), seq_num)
              {new_tracker, true, w_sm, false}
            end
        end
      else
        # No sequence number in metadata, skip validation
        {seq_tracker, true, w_sm, false}
      end

    # Reset fragments if needed (due to gap during fragmentation)
    state =
      if should_reset_fragments? do
        # Cancel fragment timer since we're discarding accumulated fragments
        state = cancel_fragment_timer(state)

        %{
          state
          | acc: [],
            frag_acc: [],
            first_pts: nil,
            w_state_machine: w_sm,
            seq_tracker: seq_tracker
        }
      else
        %{state | w_state_machine: w_sm, seq_tracker: seq_tracker}
      end

    # Skip processing if sequence validation failed
    if not seq_valid? do
      {[], state}
    else
      # Parse minimal header
      header_mode = Map.get(state, :header_mode, :draft)

      case decode_header(payload, header_mode) do
        {:ok, header, rest, full_header} when header_mode == :spec ->
          # Full header available - process with metadata
          process_packet_with_full_header(
            state,
            header,
            rest,
            full_header,
            marker,
            first_pts
          )

        {:ok, header, rest} ->
          # Basic header only (draft mode or fallback)
          process_packet_basic(state, header, rest, marker, first_pts)

        :error ->
          # If header cannot be parsed, fall back to concatenating raw payload
          # Zero-copy: Use IO list accumulation instead of binary concatenation
          acc = [state.acc | payload]

          if marker do
            # Use appropriate output pad based on per_layer_output setting
            per_layer_output = Map.get(state, :per_layer_output, false)

            {pad_ref, pad_actions, new_state} =
              if per_layer_output do
                # Per-layer mode: use dynamic pad with layer 0
                pad_ref = Pad.ref(:output, 0)
                discovered_layers = Map.get(state, :discovered_layers, MapSet.new())

                if MapSet.member?(discovered_layers, 0) do
                  {pad_ref, [], state}
                else
                  new_discovered_layers = MapSet.put(discovered_layers, 0)

                  {pad_ref, [notify_parent: {:new_pad, pad_ref}],
                   %{state | discovered_layers: new_discovered_layers}}
                end
              else
                # Single output mode: use static :output pad
                {:output, [], state}
              end

            # Flatten IO list to binary when creating final buffer
            buffer = %Buffer{payload: IO.iodata_to_binary(acc), pts: first_pts}
            buffer_action = {:buffer, {pad_ref, buffer}}
            actions = pad_actions ++ [buffer_action]
            {actions, %{new_state | acc: [], first_pts: nil}}
          else
            {[], %{state | acc: acc, first_pts: first_pts}}
          end
      end
    end
  end

  # Extract W value from header struct
  defp get_w_value(%{fragmented?: false}), do: 0
  defp get_w_value(%{start?: true, end?: true}), do: 0
  defp get_w_value(%{start?: true, end?: false}), do: 1
  defp get_w_value(%{start?: false, end?: false}), do: 2
  defp get_w_value(%{start?: false, end?: true}), do: 3

  # Check if packet should be filtered based on layer constraints
  # Returns {:filter, reason} if packet should be dropped, or :pass if it should be processed
  defp should_filter_packet?(full_header, max_temporal_id, max_spatial_id) do
    temporal_exceeds? =
      max_temporal_id != nil and full_header.temporal_id != nil and
        full_header.temporal_id > max_temporal_id

    spatial_exceeds? =
      max_spatial_id != nil and full_header.spatial_id != nil and
        full_header.spatial_id > max_spatial_id

    cond do
      temporal_exceeds? and spatial_exceeds? ->
        {:filter, :both_layers_exceed_threshold}

      temporal_exceeds? ->
        {:filter, :temporal_layer_exceeds_threshold}

      spatial_exceeds? ->
        {:filter, :spatial_layer_exceeds_threshold}

      true ->
        :pass
    end
  end

  # Process packet with full header information (spec mode)
  defp process_packet_with_full_header(
         state,
         header,
         rest,
         full_header,
         marker,
         first_pts
       ) do
    # Check layer filtering constraints
    max_temporal_id = Map.get(state, :max_temporal_id)
    max_spatial_id = Map.get(state, :max_spatial_id)

    case should_filter_packet?(full_header, max_temporal_id, max_spatial_id) do
      {:filter, reason} ->
        # Packet exceeds layer thresholds - filter it out
        require Membrane.Logger

        Membrane.Logger.debug(
          "Filtering packet: temporal_id=#{inspect(full_header.temporal_id)}, " <>
            "spatial_id=#{inspect(full_header.spatial_id)}, " <>
            "max_temporal_id=#{inspect(max_temporal_id)}, " <>
            "max_spatial_id=#{inspect(max_spatial_id)}, reason=#{reason}"
        )

        # Emit telemetry event
        :telemetry.execute(
          [:membrane_rtp_av1, :depayloader, :layer_filtered],
          %{count: 1},
          %{
            temporal_id: full_header.temporal_id,
            spatial_id: full_header.spatial_id,
            max_temporal_id: max_temporal_id,
            max_spatial_id: max_spatial_id,
            reason: reason
          }
        )

        # Return empty actions and unchanged state (packet is dropped)
        {[], state}

      :pass ->
        # Packet passes layer constraints - process normally
        process_packet_with_full_header_impl(state, header, rest, full_header, marker, first_pts)
    end
  end

  # Internal implementation of packet processing (after layer filtering)
  defp process_packet_with_full_header_impl(
         state,
         header,
         rest,
         full_header,
         marker,
         first_pts
       ) do
    # Cache SS if present
    cached_ss =
      if full_header.z and full_header.scalability_structure != nil do
        full_header.scalability_structure
      else
        state.cached_ss
      end

    # Validate W-bit state transition
    w_value = get_w_value(header)
    w_sm = Map.get(state, :w_state_machine, WBitStateMachine.new())
    seq_tracker = Map.get(state, :seq_tracker, SequenceTracker.new())

    case WBitStateMachine.next(w_sm, w_value) do
      {:ok, new_w_sm} ->
        # Valid W transition, process packet based on fragmentation state
        {acc, frag_acc, timer_action} =
          process_packet_payload(header, rest, state.acc, state.frag_acc)

        # Manage fragment timeout timer based on W-bit state
        state =
          case timer_action do
            :start_timer -> start_fragment_timer(state)
            :cancel_timer -> cancel_fragment_timer(state)
            :none -> state
          end

        # Flush access unit only when marker bit is set
        # W=3 completes a fragment, but access unit continues until marker
        if marker do
          # Build metadata from full header
          av1_metadata = build_av1_metadata(full_header, cached_ss)
          metadata = %{av1: av1_metadata}

          # Determine output pad (per-layer or single output)
          {output_pad, pad_actions, state_with_pad} =
            determine_output_pad(full_header, %{state | cached_ss: cached_ss})

          # Zero-copy: Flatten IO list to binary only when creating final buffer
          buffer = %Buffer{payload: IO.iodata_to_binary(acc), pts: first_pts, metadata: metadata}
          buffer_action = {:buffer, {output_pad, buffer}}
          actions = pad_actions ++ [buffer_action]

          {actions,
           %{
             state_with_pad
             | acc: [],
               frag_acc: frag_acc,
               first_pts: nil,
               w_state_machine: new_w_sm,
               seq_tracker: seq_tracker,
               cached_ss: cached_ss
           }}
        else
          # Check accumulation sizes before updating state
          case check_accumulation_size(acc, frag_acc, state) do
            :ok ->
              {[],
               %{
                 state
                 | acc: acc,
                   frag_acc: frag_acc,
                   first_pts: first_pts,
                   w_state_machine: new_w_sm,
                   seq_tracker: seq_tracker,
                   cached_ss: cached_ss
               }}

            {:error, type, size, limit} ->
              # Accumulation size limit exceeded - emit telemetry and reset
              :telemetry.execute(
                [:membrane_rtp_av1, :depayloader, :accumulation_limit_exceeded],
                %{size: size, limit: limit},
                %{type: type, action: :reset}
              )

              require Membrane.Logger

              Membrane.Logger.warning(
                "Accumulation size limit exceeded: #{type} (#{size} bytes > #{limit} bytes). " <>
                  "Resetting accumulators and emitting discontinuity event."
              )

              # Cancel fragment timer and reset state
              state = cancel_fragment_timer(state)

              {[event: {:output, %Membrane.Event.Discontinuity{}}],
               %{
                 state
                 | acc: [],
                   frag_acc: [],
                   first_pts: nil,
                   w_state_machine: WBitStateMachine.reset(w_sm),
                   seq_tracker: seq_tracker,
                   cached_ss: cached_ss
               }}
          end
        end

      {:error, reason} ->
        # Invalid W transition - log error and reset state machine
        require Membrane.Logger

        Membrane.Logger.warning(
          "Invalid W-bit transition: #{WBitStateMachine.error_message({:error, reason})}. " <>
            "Resetting fragment state and discarding accumulated data."
        )

        # Reset state machine and discard incomplete fragments
        new_w_sm = WBitStateMachine.reset(w_sm)

        # Cancel fragment timer since we're discarding accumulated fragments
        state = cancel_fragment_timer(state)

        {[],
         %{
           state
           | acc: [],
             frag_acc: [],
             first_pts: nil,
             w_state_machine: new_w_sm,
             seq_tracker: seq_tracker,
             cached_ss: cached_ss
         }}
    end
  end

  # Process packet payload handling both aggregation and fragmentation
  # Returns {access_unit_acc, fragment_acc, timer_action}
  # timer_action: :start_timer | :cancel_timer | :none
  # Note: Fragments (W=1,2,3) contain pieces of LEB128-framed OBUs, so reassembly
  # just concatenates them back together without additional framing.
  # Zero-copy optimization: Uses IO lists for accumulation to avoid intermediate copies
  defp process_packet_payload(header, payload, au_acc, frag_acc) do
    cond do
      # W=0: Complete OBUs (aggregated), already LEB128-framed
      not header.fragmented? ->
        # Payload contains complete LEB128-framed OBUs
        # Append directly to access unit accumulator using IO list
        {[au_acc | payload], frag_acc, :none}

      # W=1: First fragment of a LEB128-framed OBU
      header.start? and not header.end? ->
        # Start accumulating fragment bytes (includes start of LEB128 length prefix)
        # Start timeout timer for fragment reassembly
        {au_acc, payload, :start_timer}

      # W=2: Middle fragment of a LEB128-framed OBU
      not header.start? and not header.end? ->
        # Continue accumulating fragment bytes using IO list
        {au_acc, [frag_acc | payload], :none}

      # W=3: Last fragment of a LEB128-framed OBU
      not header.start? and header.end? ->
        # Complete the fragment (reassembles original LEB128-framed OBU)
        complete_fragment = [frag_acc | payload]

        # Append reassembled OBU to access unit (no additional framing needed)
        # Cancel timeout timer since fragment is complete
        {[au_acc | complete_fragment], [], :cancel_timer}

      # W=0 (both start and end): Single complete unfragmented OBU
      true ->
        # This is actually covered by the first case, but being explicit
        {[au_acc | payload], frag_acc, :none}
    end
  end

  # Process packet with basic header only (draft mode or fallback)
  defp process_packet_basic(state, header, rest, marker, first_pts) do
    # Validate W-bit state transition
    w_value = get_w_value(header)
    w_sm = Map.get(state, :w_state_machine, WBitStateMachine.new())
    seq_tracker = Map.get(state, :seq_tracker, SequenceTracker.new())

    case WBitStateMachine.next(w_sm, w_value) do
      {:ok, new_w_sm} ->
        # Valid W transition, process packet payload
        {acc, frag_acc, timer_action} =
          process_packet_payload(header, rest, state.acc, state.frag_acc)

        # Manage fragment timeout timer based on W-bit state
        state =
          case timer_action do
            :start_timer -> start_fragment_timer(state)
            :cancel_timer -> cancel_fragment_timer(state)
            :none -> state
          end

        # Flush access unit only when marker bit is set
        # W=3 completes a fragment, but access unit continues until marker
        if marker do
          # Use appropriate output pad based on per_layer_output setting
          per_layer_output = Map.get(state, :per_layer_output, false)

          {pad_ref, pad_actions, new_state} =
            if per_layer_output do
              # Per-layer mode: use dynamic pad with layer 0
              pad_ref = Pad.ref(:output, 0)
              discovered_layers = Map.get(state, :discovered_layers, MapSet.new())

              if MapSet.member?(discovered_layers, 0) do
                {pad_ref, [], state}
              else
                new_discovered_layers = MapSet.put(discovered_layers, 0)

                {pad_ref, [notify_parent: {:new_pad, pad_ref}],
                 %{state | discovered_layers: new_discovered_layers}}
              end
            else
              # Single output mode: use static :output pad
              {:output, [], state}
            end

          # Zero-copy: Flatten IO list to binary only when creating final buffer
          buffer = %Buffer{payload: IO.iodata_to_binary(acc), pts: first_pts}
          buffer_action = {:buffer, {pad_ref, buffer}}
          actions = pad_actions ++ [buffer_action]

          {actions,
           %{
             new_state
             | acc: [],
               frag_acc: frag_acc,
               first_pts: nil,
               w_state_machine: new_w_sm,
               seq_tracker: seq_tracker
           }}
        else
          # Check accumulation sizes before updating state
          case check_accumulation_size(acc, frag_acc, state) do
            :ok ->
              {[],
               %{
                 state
                 | acc: acc,
                   frag_acc: frag_acc,
                   first_pts: first_pts,
                   w_state_machine: new_w_sm,
                   seq_tracker: seq_tracker
               }}

            {:error, type, size, limit} ->
              # Accumulation size limit exceeded - emit telemetry and reset
              :telemetry.execute(
                [:membrane_rtp_av1, :depayloader, :accumulation_limit_exceeded],
                %{size: size, limit: limit},
                %{type: type, action: :reset}
              )

              require Membrane.Logger

              Membrane.Logger.warning(
                "Accumulation size limit exceeded: #{type} (#{size} bytes > #{limit} bytes). " <>
                  "Resetting accumulators and emitting discontinuity event."
              )

              # Cancel fragment timer and reset state
              state = cancel_fragment_timer(state)

              {[event: {:output, %Membrane.Event.Discontinuity{}}],
               %{
                 state
                 | acc: [],
                   frag_acc: [],
                   first_pts: nil,
                   w_state_machine: WBitStateMachine.reset(w_sm),
                   seq_tracker: seq_tracker
               }}
          end
        end

      {:error, reason} ->
        # Invalid W transition - log error and reset state machine
        require Membrane.Logger

        Membrane.Logger.warning(
          "Invalid W-bit transition: #{WBitStateMachine.error_message({:error, reason})}. " <>
            "Resetting fragment state and discarding accumulated data."
        )

        # Reset state machine and discard incomplete fragments
        new_w_sm = WBitStateMachine.reset(w_sm)

        # Cancel fragment timer since we're discarding accumulated fragments
        state = cancel_fragment_timer(state)

        {[],
         %{
           state
           | acc: [],
             frag_acc: [],
             first_pts: nil,
             w_state_machine: new_w_sm,
             seq_tracker: seq_tracker
         }}
    end
  end

  # Build AV1 metadata from full header
  defp build_av1_metadata(full_header, cached_ss) do
    %{
      temporal_id: full_header.temporal_id,
      spatial_id: full_header.spatial_id,
      has_ss: full_header.z,
      scalability_structure: full_header.scalability_structure || cached_ss,
      n_flag: full_header.n,
      y_flag: full_header.y
    }
  end

  # Determine output pad for buffer based on per_layer_output mode and temporal_id
  # Returns {output_pad_ref, updated_actions, updated_state}
  defp determine_output_pad(full_header, state) do
    per_layer_output = Map.get(state, :per_layer_output, false)

    if per_layer_output do
      # Per-layer output mode: route to layer-specific dynamic pads
      # Note: This mode is NOT compatible with Membrane.RTP.DepayloaderBin
      # Use the depayloader directly in your pipeline for this advanced feature
      require Membrane.Logger

      Membrane.Logger.warning(
        "per_layer_output mode is not compatible with Membrane.RTP.DepayloaderBin. " <>
          "Use the depayloader directly in your pipeline and handle dynamic pad creation."
      )

      # Default to layer 0 if temporal_id is nil
      layer_id = full_header.temporal_id || 0
      pad_ref = Pad.ref(:output, layer_id)
      discovered_layers = Map.get(state, :discovered_layers, MapSet.new())

      if MapSet.member?(discovered_layers, layer_id) do
        # Layer already discovered, no need to notify parent
        {pad_ref, [], state}
      else
        # New layer discovered, notify parent to create pad
        Membrane.Logger.info(
          "Discovered new temporal layer #{layer_id}, requesting output pad #{inspect(pad_ref)}"
        )

        new_discovered_layers = MapSet.put(discovered_layers, layer_id)
        new_state = %{state | discovered_layers: new_discovered_layers}

        # Notify parent to create the pad
        actions = [notify_parent: {:new_pad, pad_ref}]
        {pad_ref, actions, new_state}
      end
    else
      # Default single output mode: use static :output pad
      # This is compatible with Membrane.RTP.DepayloaderBin
      {:output, [], state}
    end
  end

  defp decode_header(<<_::binary>> = payload, :draft) do
    Header.decode(payload)
  end

  defp decode_header(<<_::binary>> = payload, :spec) do
    case FullHeader.decode(payload) do
      {:ok, fh, rest} ->
        # Extract basic header info for W-bit state machine
        fragmented? = fh.w != 0
        start? = fh.y
        end? = fh.w in [0, 3]

        # Create basic header with additional full header metadata
        header = %Header{
          start?: start?,
          end?: end?,
          fragmented?: fragmented?,
          obu_count: 0
        }

        # Return header with full header info for metadata extraction
        {:ok, header, rest, fh}

      _ ->
        # Fallback to previous spec-like header if full header isn't present
        with {:ok, spec, rest} <- SpecHeader.decode(payload) do
          fragmented? = spec.w != 0
          start? = spec.y
          end? = spec.w in [0, 3]
          header = %Header{start?: start?, end?: end?, fragmented?: fragmented?, obu_count: 0}
          {:ok, header, rest}
        else
          _ -> :error
        end
    end
  end

  @impl true
  def handle_info(:fragment_timeout, _ctx, state) do
    require Membrane.Logger

    # Check if we still have fragments accumulated
    if state.frag_acc != [] and state.fragment_start_time != nil do
      fragment_age_ms =
        System.monotonic_time(:millisecond) - state.fragment_start_time

      accumulated_bytes =
        state.frag_acc |> IO.iodata_length()

      Membrane.Logger.warning(
        "Fragment timeout after #{fragment_age_ms}ms with #{accumulated_bytes} bytes accumulated. Discarding incomplete fragment."
      )

      # Emit telemetry for monitoring
      :telemetry.execute(
        [:membrane_rtp_av1, :depayloader, :fragment_timeout],
        %{fragment_age_ms: fragment_age_ms, accumulated_bytes: accumulated_bytes},
        %{reason: :timeout}
      )

      # Emit discontinuity event
      event = %Membrane.Event.Discontinuity{}
      actions = [event: {:output, event}]

      # Reset fragment state
      new_state = %{
        state
        | frag_acc: [],
          fragment_timer_ref: nil,
          fragment_start_time: nil,
          w_state_machine: WBitStateMachine.reset(state.w_state_machine)
      }

      {actions, new_state}
    else
      # Timeout fired but no fragments accumulated (race condition)
      # This can happen if W=3 arrives just as timeout fires
      new_state = %{
        state
        | fragment_timer_ref: nil,
          fragment_start_time: nil
      }

      {[], new_state}
    end
  end

  # Helper: Check accumulation sizes to prevent memory exhaustion
  defp check_accumulation_size(acc, frag_acc, state) do
    acc_size = IO.iodata_length(acc)
    frag_size = IO.iodata_length(frag_acc)

    max_fragment_size = Map.get(state, :max_fragment_size, 1_000_000)
    max_access_unit_size = Map.get(state, :max_access_unit_size, 10_000_000)

    cond do
      frag_size > max_fragment_size ->
        {:error, :fragment_too_large, frag_size, max_fragment_size}

      acc_size > max_access_unit_size ->
        {:error, :access_unit_too_large, acc_size, max_access_unit_size}

      true ->
        :ok
    end
  end

  # Helper: Start fragment timeout timer when W=1 packet is received
  defp start_fragment_timer(state) do
    # Cancel any existing timer first
    state = cancel_fragment_timer(state)

    # Get timeout value, default to 500ms if not configured
    timeout_ms = Map.get(state, :fragment_timeout_ms, 500)

    # Start new timer
    timer_ref = Process.send_after(self(), :fragment_timeout, timeout_ms)
    start_time = System.monotonic_time(:millisecond)

    %{
      state
      | fragment_timer_ref: timer_ref,
        fragment_start_time: start_time
    }
  end

  # Helper: Cancel fragment timeout timer when W=3 packet is received or gap detected
  defp cancel_fragment_timer(state) do
    if state.fragment_timer_ref != nil do
      Process.cancel_timer(state.fragment_timer_ref)
    end

    %{
      state
      | fragment_timer_ref: nil,
        fragment_start_time: nil
    }
  end
end
