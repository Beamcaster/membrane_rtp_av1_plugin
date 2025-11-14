defmodule Membrane.RTP.AV1 do
  @moduledoc """
  RTP payload format registration for AV1.

  This module registers AV1 with the Membrane RTP framework, making it
  discoverable by RTP muxers, demuxers, and other generic RTP components.

  The registration includes:
  - Encoding name: `:AV1`
  - Clock rate: `90000` Hz (fixed per AV1 RTP spec)
  - Payloader: `Membrane.RTP.AV1.Payloader`
  - Depayloader: `Membrane.RTP.AV1.Depayloader`

  ## Usage

  The registration happens automatically when the application starts.
  No manual registration is needed.

  ## Example

      # In a pipeline, the RTP muxer can automatically discover AV1 format:
      child(:source, %MySource{})
      |> child(:payloader, %Membrane.RTP.AV1.Payloader{})
      |> child(:rtp_muxer, Membrane.RTP.Muxer)

  """

  alias Membrane.RTP.PayloadFormat

  @encoding_name :AV1
  @clock_rate 90_000

  @doc """
  Returns the registered encoding name for AV1.
  """
  @spec encoding_name() :: atom()
  def encoding_name, do: @encoding_name

  @doc """
  Returns the clock rate for AV1 RTP streams.
  """
  @spec clock_rate() :: pos_integer()
  def clock_rate, do: @clock_rate

  @doc false
  def __register__() do
    PayloadFormat.register(%PayloadFormat{
      encoding_name: @encoding_name,
      payloader: Membrane.RTP.AV1.Payloader,
      depayloader: Membrane.RTP.AV1.Depayloader,
      # AV1 doesn't have a static payload type - uses dynamic range (96-127)
      payload_type: nil
    })

    :ok
  end
end
