defmodule Membrane.RTP.AV1.Rav1dDecoder do
  @moduledoc """
  AV1 video decoder using the rav1d (Rust dav1d bindings) library.

  This element decodes AV1 temporal units into raw YUV frames.

  ## Input/Output

  - **Input**: AV1 temporal units (`Membrane.RTP.AV1.Format`)
  - **Output**: Raw YUV frames (`Membrane.RawVideo`, I420 pixel format)

  ## Usage

  Typically used after an AV1 depayloader in an RTP pipeline:

      child(:rtp_parser, Membrane.RTP.Parser)
      |> child(:depayloader, Membrane.RTP.AV1.ExWebRTCDepayloader)
      |> child(:decoder, Membrane.RTP.AV1.Rav1dDecoder)
      |> child(:sink, YourVideoSink)

  ## Options

  - `:clock_rate` - RTP clock rate for PTS conversion (default: 90000 Hz)
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, RawVideo}
  alias Membrane.RTP.AV1.Format

  def_input_pad :input,
    accepted_format: Format,
    flow_control: :auto

  def_output_pad :output,
    accepted_format: RawVideo,
    flow_control: :auto

  def_options clock_rate: [
                spec: pos_integer(),
                default: 90_000,
                description: "RTP clock rate in Hz for PTS conversion (default: 90000 for video)"
              ]

  @impl true
  def handle_init(_ctx, opts) do
    case Rav1dEx.new() do
      {:ok, decoder} ->
        state = %{
          decoder: decoder,
          clock_rate: opts.clock_rate,
          stream_format_sent: false,
          frame_count: 0
        }

        {[], state}

      {:error, reason} ->
        raise "Failed to initialize rav1d decoder: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    # We'll send our own RawVideo stream format when we decode the first frame
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %Buffer{payload: temporal_unit, pts: pts} = buffer

    if byte_size(temporal_unit) == 0 do
      Membrane.Logger.debug("Empty temporal unit received, skipping")
      {[], state}
    else
      decode_temporal_unit(temporal_unit, pts, state)
    end
  end

  # Decode a complete AV1 temporal unit
  defp decode_temporal_unit(temporal_unit, pts, state) do
    Membrane.Logger.debug("""
    Decoding temporal unit:
    - Size: #{byte_size(temporal_unit)} bytes
    - First 32 bytes (hex): #{temporal_unit |> binary_part(0, min(32, byte_size(temporal_unit))) |> Base.encode16(case: :lower)}
    """)

    case Rav1dEx.decode_access_unit(state.decoder, temporal_unit) do
      {:ok, frames} when is_list(frames) and frames != [] ->
        process_decoded_frames(frames, pts, state)

      {:ok, []} ->
        # Decoder needs more data (e.g., buffering for B-frames)
        Membrane.Logger.debug("Decoder needs more data (no frames output yet)")
        {[], state}

      {:error, reason} ->
        Membrane.Logger.warning("rav1d decode failed: #{inspect(reason)}")
        # Emit discontinuity event on decode error
        event = %Membrane.Event.Discontinuity{}
        {[event: {:output, event}], state}
    end
  end

  defp process_decoded_frames(frames, pts, state) do
    {actions, new_state} =
      Enum.reduce(frames, {[], state}, fn frame, {acc_actions, acc_state} ->
        # Send stream format on first frame
        {format_actions, format_state} =
          if not acc_state.stream_format_sent do
            send_stream_format(frame, acc_state)
          else
            {[], acc_state}
          end

        # Create output buffer
        frame_buffer = create_frame_buffer(frame, pts, format_state)

        # Combine actions
        new_actions = acc_actions ++ format_actions ++ [buffer: {:output, frame_buffer}]
        new_state = %{format_state | frame_count: format_state.frame_count + 1}

        {new_actions, new_state}
      end)

    {actions, new_state}
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

  defp create_frame_buffer(frame, pts, state) do
    # Combine YUV planes into single buffer (I420 format: Y, then U, then V)
    yuv_data = frame.y_plane <> frame.u_plane <> frame.v_plane

    # Use frame timestamp if available, otherwise use buffer PTS
    output_pts =
      if frame.timestamp != 0 do
        Membrane.Time.seconds(frame.timestamp / state.clock_rate)
      else
        pts
      end

    %Buffer{
      payload: yuv_data,
      pts: output_pts,
      metadata: %{
        width: frame.width,
        height: frame.height,
        pixel_format: :I420,
        frame_number: state.frame_count
      }
    }
  end
end
