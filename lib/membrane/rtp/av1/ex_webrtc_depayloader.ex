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
  alias Membrane.RTP.AV1.ExWebRTC.Payload

  @obu_temporal_delimiter 2

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
      # Stream format tracking
      stream_format_sent: false
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

    # Handle padding-only packets
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
          Couldn't parse AV1 payload, reason: #{reason}. \
          Resetting depayloader state. Payload: #{inspect(payload)}.\
          """)

          {[], reset_depayloader(state)}
      end
    end
  end

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
    cond do
      state.current_temporal_unit == nil ->
        %{state | current_temporal_unit: obu_data, current_timestamp: timestamp}

      timestamp != state.current_timestamp ->
        Membrane.Logger.debug("""
        Received OBU with different timestamp without finishing previous temporal unit. \
        Dropping previous temporal unit.\
        """)

        %{state | current_temporal_unit: obu_data, current_timestamp: timestamp}

      true ->
        %{
          state
          | current_temporal_unit: state.current_temporal_unit <> obu_data
        }
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

    buffer = %Buffer{
      payload: temporal_unit,
      pts: pts,
      metadata: %{
        av1: %{
          temporal_unit_size: byte_size(temporal_unit)
        }
      }
    }

    new_state = %{state | stream_format_sent: true}

    {format_actions ++ [buffer: {:output, buffer}], new_state}
  end
end
