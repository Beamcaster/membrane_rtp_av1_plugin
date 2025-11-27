defmodule Membrane.RTP.AV1.Rav1Depayloader do
  @moduledoc """
  RTP depayloader for AV1 video using the rav1_ex Rust decoder.

  This element combines RTP depayloading and AV1 decoding in a single step,
  outputting raw YUV frames ready for display or further processing.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, RawVideo, RTP}
  alias Membrane.RTP.AV1.{FullHeader, Header, OBU}
  alias Membrane.RTP.AV1.Rav1Depayloader.Reorder

  def_input_pad :input,
    accepted_format: RTP,
    flow_control: :auto

  def_output_pad :output,
    accepted_format: RawVideo,
    flow_control: :auto

  def_options clock_rate: [
                spec: pos_integer(),
                default: 90_000,
                description: "RTP clock rate in Hz (default: 90000 for video)"
              ],
              header_mode: [
                spec: :spec | :draft | :auto,
                default: :auto,
                description:
                  "AV1 RTP header mode: :spec (RFC standard), :draft (legacy), or :auto (auto-detect)"
              ],
              max_reorder_buffer: [
                spec: pos_integer(),
                default: 10,
                description: "Maximum packets to buffer for reordering per RTP timestamp"
              ],
              max_seq_gap: [
                spec: pos_integer(),
                default: 5,
                description:
                  "Maximum sequence number gap to tolerate before skipping missing packets"
              ],
              reorder_timeout_ms: [
                spec: pos_integer(),
                default: 500,
                description: "Timeout for incomplete reorder contexts in milliseconds"
              ]

  @impl true
  def handle_init(_ctx, opts) do
    case Rav1dEx.new() do
      {:ok, decoder} ->
        state = %{
          # Decoder
          decoder: decoder,
          clock_rate: opts.clock_rate,
          stream_format_sent: false,
          frame_count: 0,
          # RTP depacketization state - Reorder module for packet buffering
          reorder: %{},
          # Map of rtp_timestamp -> Reorder context
          fragment_queue: Qex.new(),
          complete_obu_queue: Qex.new(),
          first_pts: nil,
          # Configuration
          header_mode: opts.header_mode,
          max_reorder_buffer: opts.max_reorder_buffer,
          max_seq_gap: opts.max_seq_gap,
          reorder_timeout_ms: opts.reorder_timeout_ms,
          # Metadata
          cached_scalability_structure: nil
        }

        {[], state}

      {:error, reason} ->
        raise "Failed to initialize rav1d decoder: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    # RTP Parser provides RemoteStream format
    # We'll send our own stream format when we decode the first frame
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %Buffer{payload: payload, pts: pts, metadata: metadata} = buffer

    # Extract RTP metadata
    marker = get_in(metadata, [:rtp, :marker]) || false
    seq_num = get_in(metadata, [:rtp, :sequence_number])
    rtp_timestamp = get_in(metadata, [:rtp, :timestamp]) || 0

    # Decode AV1 RTP header
    case decode_av1_header(payload, state.header_mode) do
      {:ok, header_info, obu_payload, full_header} ->
        # Build packet for reorder module
        packet = %{
          seq: seq_num,
          payload: {header_info, obu_payload, full_header},
          marker: marker,
          pts: pts,
          ts: rtp_timestamp
        }

        opts = %{
          max_reorder_buffer: state.max_reorder_buffer,
          max_seq_gap: state.max_seq_gap
        }

        # Insert into reorder buffer
        {new_state, result} = Reorder.insert_packet(state, packet, opts)

        case result do
          {:ok, au_packets, au_pts} ->
            # Process complete access unit
            process_access_unit_packets(au_packets, au_pts, new_state)

          :pending ->
            # Still buffering
            {[], new_state}
        end

      {:error, reason} ->
        Membrane.Logger.warning("AV1 header decode failed: #{inspect(reason)}")
        emit_discontinuity(state)
    end
  end

  # Private helper functions

  # Process access unit packets from Reorder module
  defp process_access_unit_packets(au_packets, au_pts, state) do
    # Update first PTS
    state = %{state | first_pts: state.first_pts || au_pts}

    # Process each packet through W-bit logic
    state =
      Enum.reduce(au_packets, state, fn {header_info, obu_payload, full_header}, acc_state ->
        # Update cached scalability structure if present
        acc_state =
          if full_header && full_header.scalability_structure do
            %{acc_state | cached_scalability_structure: full_header.scalability_structure}
          else
            acc_state
          end

        # Process based on W-bit, accumulating OBUs
        process_w_bit(header_info, obu_payload, acc_state)
      end)

    # Access unit is complete (marker bit was set in reorder), decode it
    complete_access_unit(state)
  end

  # AV1 Header decoding

  defp decode_av1_header(payload, mode) do
    case mode do
      :spec ->
        decode_spec_header(payload)

      :draft ->
        decode_draft_header(payload)

      :auto ->
        # Try spec first, fallback to draft
        case decode_spec_header(payload) do
          {:ok, _, _, _} = result -> result
          {:error, _} -> decode_draft_header(payload)
        end
    end
  end

  defp decode_spec_header(payload) do
    case FullHeader.decode(payload) do
      {:ok, header, rest} ->
        header_info = %{
          w: header.w,
          fragmented?: header.w != 0,
          start?: header.w == 1,
          end?: header.w == 3 or header.w == 0,
          y: header.y,
          n: header.n,
          temporal_id: header.temporal_id,
          spatial_id: header.spatial_id
        }

        {:ok, header_info, rest, header}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_draft_header(payload) do
    case Header.decode(payload) do
      {:ok, header, rest} ->
        # Map spec header Z/Y to common format
        # z=1 means continuation (NOT start), y=1 means continues (NOT end)
        start? = not header.z
        end? = not header.y
        fragmented? = header.z or header.y

        header_info = %{
          w: header.w,
          fragmented?: fragmented?,
          start?: start?,
          end?: end?,
          y: header.y,
          n: header.n,
          temporal_id: nil,
          spatial_id: nil
        }

        {:ok, header_info, rest, nil}

      :error ->
        {:error, :invalid_draft_header}
    end
  end

  # W-bit processing with Qex queues
  # W-bit determines OBU fragmentation state
  # Complete OBUs (W=0 and W=3) are wrapped with external LEB128 for NIF Annex B detection
  # The NIF strips the LEB128 framing and sends raw OBUs to dav1d

  defp process_w_bit(header_info, payload, state) do
    frag_queue_size = Enum.count(state.fragment_queue)
    payload_size = byte_size(payload)

    Membrane.Logger.debug(
      "W=#{header_info.w}, payload_size=#{payload_size}, frag_queue_size=#{frag_queue_size}"
    )

    case header_info.w do
      # W=0: Complete OBU(s) - wrap with external LEB128 for NIF Annex B detection
      # OBS sends OBUs with has_size_field=1, which dav1d cannot handle directly
      # By wrapping with external LEB128, NIF detects as Annex B and strips framing properly
      0 ->
        if frag_queue_size > 0 do
          Membrane.Logger.warning(
            "W=0 with #{frag_queue_size} pending fragments - discarding incomplete fragments"
          )
        end

        # Wrap with external LEB128 so NIF will strip it and send raw OBU to dav1d
        framed_payload = OBU.build_obu(payload)
        new_complete_queue = Qex.push(state.complete_obu_queue, framed_payload)

        %{
          state
          | complete_obu_queue: new_complete_queue,
            fragment_queue: Qex.new()
        }

      # W=1: First fragment - start new fragment queue
      # Store raw OBU fragment data (framing added when complete in W=3)
      1 ->
        if frag_queue_size > 0 do
          Membrane.Logger.warning("W=1 received, discarding #{frag_queue_size} pending fragments")
        end

        # Start new fragment queue with this raw OBU fragment
        new_frag_queue = Qex.new() |> Qex.push(payload)
        %{state | fragment_queue: new_frag_queue}

      # W=2: Middle fragment - append to fragment queue
      # Store raw OBU fragment data (framing added when complete in W=3)
      2 ->
        if frag_queue_size == 0 do
          Membrane.Logger.warning("W=2 received without W=1 start - starting new fragment")
          new_frag_queue = Qex.new() |> Qex.push(payload)
          %{state | fragment_queue: new_frag_queue}
        else
          new_frag_queue = Qex.push(state.fragment_queue, payload)
          %{state | fragment_queue: new_frag_queue}
        end

      # W=3: Last fragment - complete and wrap with LEB128 for NIF
      # Assemble fragments and wrap with external LEB128 for Annex B detection
      3 ->
        if frag_queue_size == 0 do
          Membrane.Logger.warning("W=3 received without fragments - treating as complete OBU")
          # Single fragment: wrap with LEB128
          framed_obu = OBU.build_obu(payload)
          new_complete_queue = Qex.push(state.complete_obu_queue, framed_obu)
          %{state | complete_obu_queue: new_complete_queue}
        else
          # Assemble all fragments including this final one
          all_fragments =
            state.fragment_queue
            |> Enum.to_list()
            |> Kernel.++([payload])

          # Concatenate raw OBU fragments
          complete_obu_data = IO.iodata_to_binary(all_fragments)

          Membrane.Logger.debug(
            "W=3 completed fragment, total OBU size: #{byte_size(complete_obu_data)} bytes"
          )

          # Wrap with external LEB128 for NIF Annex B detection
          framed_obu = OBU.build_obu(complete_obu_data)
          new_complete_queue = Qex.push(state.complete_obu_queue, framed_obu)

          %{
            state
            | complete_obu_queue: new_complete_queue,
              fragment_queue: Qex.new()
          }
        end
    end
  end

  # Access unit completion and decoding

  defp complete_access_unit(state) do
    # Convert complete OBU queue to bytestream
    obu_list = Enum.to_list(state.complete_obu_queue)
    obu_bytestream = IO.iodata_to_binary(obu_list)

    if byte_size(obu_bytestream) == 0 do
      # Empty access unit - reset state
      reset_state = %{state | complete_obu_queue: Qex.new(), first_pts: nil}
      {[], reset_state}
    else
      Membrane.Logger.warning("""
      Access unit complete:
      - Total OBUs: #{length(obu_list)}
      - Total size: #{byte_size(obu_bytestream)} bytes
      - First 64 bytes (hex): #{obu_bytestream |> binary_part(0, min(64, byte_size(obu_bytestream))) |> Base.encode16(case: :lower)}
      """)

      case Rav1dEx.decode_access_unit(state.decoder, obu_bytestream) do
        {:ok, frames} when is_list(frames) and frames != [] ->
          process_decoded_frames(frames, state)

        {:ok, []} ->
          # No frames yet (decoder needs more data)
          Membrane.Logger.debug("Decoder needs more data (no frames output yet)")
          reset_state = %{state | complete_obu_queue: Qex.new(), first_pts: nil}
          {[], reset_state}

        {:error, reason} ->
          Membrane.Logger.warning("NIF call failed: #{inspect(reason)}")
          emit_discontinuity(%{state | complete_obu_queue: Qex.new(), first_pts: nil})
      end
    end
  end

  defp process_decoded_frames(frames, state) do
    {actions, new_state} =
      Enum.reduce(frames, {[], state}, fn frame, {acc_actions, acc_state} ->
        # Send stream format on first frame
        {format_actions, format_state} =
          if not acc_state.stream_format_sent do
            send_stream_format(frame, acc_state)
          else
            {[], acc_state}
          end

        # Create buffer
        frame_buffer = create_frame_buffer(frame, acc_state)

        # Combine actions
        new_actions = acc_actions ++ format_actions ++ [buffer: {:output, frame_buffer}]
        new_state = %{format_state | frame_count: format_state.frame_count + 1}

        {new_actions, new_state}
      end)

    # Reset OBU queue and PTS after successful decode
    final_state = %{new_state | complete_obu_queue: Qex.new(), first_pts: nil}

    {actions, final_state}
  end

  defp send_stream_format(frame, state) do
    stream_format = %RawVideo{
      width: frame.width,
      height: frame.height,
      pixel_format: :I420,
      aligned: true,
      framerate: nil
    }

    Membrane.Logger.info(
      "AV1 stream initialized: #{frame.width}x#{frame.height}, pixel_format: I420"
    )

    actions = [stream_format: {:output, stream_format}]
    new_state = %{state | stream_format_sent: true}

    {actions, new_state}
  end

  defp create_frame_buffer(frame, state) do
    # Combine YUV planes into single buffer (I420 format: Y, then U, then V)
    yuv_data = frame.y_plane <> frame.u_plane <> frame.v_plane

    # Convert RTP timestamp to PTS in nanoseconds
    pts =
      if frame.timestamp != 0 do
        Membrane.Time.seconds(frame.timestamp / state.clock_rate)
      else
        state.first_pts
      end

    %Buffer{
      payload: yuv_data,
      pts: pts,
      metadata: %{
        width: frame.width,
        height: frame.height,
        pixel_format: :I420
      }
    }
  end

  # Discontinuity handling

  defp emit_discontinuity(state) do
    event = %Membrane.Event.Discontinuity{}

    # Reset all depacketization state including reorder contexts and Qex queues
    reset_state = %{
      state
      | reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil
    }

    {[event: {:output, event}], reset_state}
  end
end
