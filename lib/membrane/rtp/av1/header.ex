defmodule Membrane.RTP.AV1.Header do
  @moduledoc """
  AV1 RTP payload aggregation header per RTP Payload Format for AV1 v1.0.0

  Format:
      0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |Z|Y| W |N|-|-|-|
      +-+-+-+-+-+-+-+-+

  - Z: First OBU is continuation of previous packet's fragment
  - Y: Last OBU will continue in next packet
  - W: Number of OBU elements (0=use length fields, 1-3=count)
  - N: First packet of coded video sequence (keyframe with sequence header)
  - Bits 2-0: Reserved (must be 0)
  """
  import Bitwise

  @type t :: %__MODULE__{
          z: boolean(),
          y: boolean(),
          w: 0..3,
          n: boolean()
        }

  defstruct z: false, y: false, w: 0, n: false

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{z: z, y: y, w: w, n: n})
      when is_boolean(z) and is_boolean(y) and w in 0..3 and is_boolean(n) do
    z_bit = if z, do: 1, else: 0
    y_bit = if y, do: 1, else: 0
    n_bit = if n, do: 1, else: 0

    <<z_bit <<< 7 ||| y_bit <<< 6 ||| w <<< 4 ||| n_bit <<< 3>>
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | :error
  def decode(<<byte, rest::binary>>) do
    z = (byte &&& 0b1000_0000) != 0
    y = (byte &&& 0b0100_0000) != 0
    w = byte >>> 4 &&& 0b11
    n = (byte &&& 0b0000_1000) != 0

    {:ok, %__MODULE__{z: z, y: y, w: w, n: n}, rest}
  end

  def decode(_), do: :error
end
