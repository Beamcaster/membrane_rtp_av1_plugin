defmodule Membrane.RTP.AV1 do
  @moduledoc """
  AV1 RTP payload format constants and utilities.

  This module provides constants for AV1 RTP streams:
  - Encoding name: `:AV1`
  - Clock rate: `90000` Hz (fixed per AV1 RTP spec)

  ## Main Components

  - `Membrane.RTP.AV1.ExWebRTCDepayloader` - Depayloads AV1 from RTP packets
  - `Membrane.RTP.AV1.Rav1dDecoder` - Decodes AV1 temporal units to raw video
  - `Membrane.RTP.AV1.Format` - Stream format for AV1

  ## Example Pipeline

      child(:rtp_parser, Membrane.RTP.Parser)
      |> child(:depayloader, Membrane.RTP.AV1.ExWebRTCDepayloader)
      |> child(:decoder, Membrane.RTP.AV1.Rav1dDecoder)
      |> child(:sink, YourVideoSink)
  """

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
end
