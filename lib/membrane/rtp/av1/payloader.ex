defmodule Membrane.RTP.AV1.Payloader do
  @moduledoc """
  RTP payloader for AV1.

  This is a minimal implementation that:
  - Accepts AV1 access units as input buffers
  - Splits them into MTU-sized RTP payloads
  - Sets RTP marker bit on the last packet of an access unit

  Extend to fully implement AV1 RTP payload headers and scalability signaling.
  """
  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.{PayloadFormat, Format}

  def_input_pad(:input,
    accepted_format: Format
  )

  def_output_pad(:output,
    accepted_format: Membrane.RTP
  )

  def_options(
    mtu: [
      spec: pos_integer(),
      default: 4500,
      description:
        "Maximum RTP payload size in bytes. Default: 1200 (safe), Max: 9000 (jumbo frames). Can be changed dynamically via MTUUpdateEvent."
    ],
    fmtp: [
      spec: map(),
      default: %{},
      description: "SDP fmtp parameters map (e.g., cm, tid, lid)"
    ],
    payload_type: [
      spec: 0..127,
      default: 45,
      description: "RTP dynamic payload type for AV1"
    ],
    clock_rate: [
      spec: pos_integer(),
      default: 90_000,
      description: "RTP clock rate"
    ],
    header_mode: [
      spec: atom(),
      default: :spec,
      description: "Header encoding mode for AV1 RTP payloads"
    ]
  )

  # MTU constraints
  @min_mtu 64
  @max_mtu 9000

  @impl true
  def handle_init(_ctx, opts) do
    state =
      cond do
        is_struct(opts) -> Map.from_struct(opts)
        is_map(opts) -> opts
        true -> Map.new(opts)
      end

    # Validate and clamp MTU to safe range
    mtu = validate_mtu(state.mtu)
    state = Map.put(state, :mtu, mtu)

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    stream_format = %Membrane.RTP{
      # clock_rate: 90_000
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_event(_pad, %Membrane.RTP.AV1.MTUUpdateEvent{mtu: new_mtu}, _ctx, state) do
    require Membrane.Logger

    # Validate and update MTU
    validated_mtu = validate_mtu(new_mtu)

    if validated_mtu != new_mtu do
      Membrane.Logger.warning(
        "MTU #{new_mtu} out of range [#{@min_mtu}, #{@max_mtu}], clamped to #{validated_mtu}"
      )
    end

    Membrane.Logger.info("MTU changed from #{state.mtu} to #{validated_mtu}")

    new_state = Map.put(state, :mtu, validated_mtu)
    {[], new_state}
  end

  @impl true
  def handle_event(_pad, _event, _ctx, state) do
    # Default: ignore other events
    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: access_unit, pts: pts} = _buffer, _ctx, state) do
    require Membrane.Logger
    header_mode = Map.get(state, :header_mode, :spec)

    # Use TU-aware fragmentation for proper marker bit placement
    # PayloadFormat accepts Low Overhead format directly (obu_has_size_field=1)
    result =
      PayloadFormat.fragment_with_markers(access_unit,
        mtu: state.mtu,
        header_mode: header_mode,
        fmtp: Map.get(state, :fmtp, %{}),
        tu_aware: true
      )

    actions =
      case result do
        {:error, reason, context} ->
          Membrane.Logger.error(
            "Failed to fragment access unit: #{inspect(reason)}, context: #{inspect(context)}"
          )

          []

        packets_with_markers when is_list(packets_with_markers) ->
          # Debug: Log header bytes of first packet
          Enum.with_index(packets_with_markers)
          |> Enum.map(fn {{payload, marker}, idx} ->
            # Parse and log the AV1 aggregation header
            <<header_byte, _rest::binary>> = payload
            z = (header_byte >>> 7) &&& 1
            y = (header_byte >>> 6) &&& 1
            w = (header_byte >>> 4) &&& 3
            n = (header_byte >>> 3) &&& 1
            reserved = header_byte &&& 7
            
            if idx == 0 or marker do
              Membrane.Logger.warning(
                "🎬 AV1 Payloader OUT [#{idx}]: Z=#{z}, Y=#{y}, W=#{w}, N=#{n}, reserved=#{reserved}, marker=#{marker}, size=#{byte_size(payload)}, header=0x#{Integer.to_string(header_byte, 16)}"
              )
            end
            
            metadata = %{rtp: %{marker: marker}}
            buffer = %Buffer{payload: payload, pts: pts, metadata: metadata}
            {:buffer, {:output, buffer}}
          end)
      end

    {actions, state}
  end

  # Private helpers

  @spec validate_mtu(pos_integer()) :: pos_integer()
  defp validate_mtu(mtu) when mtu < @min_mtu, do: @min_mtu
  defp validate_mtu(mtu) when mtu > @max_mtu, do: @max_mtu
  defp validate_mtu(mtu), do: mtu
end
