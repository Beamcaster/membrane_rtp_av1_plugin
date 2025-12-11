defmodule Membrane.RTP.AV1.SpecHeader do
  @moduledoc """
  Spec-like AV1 RTP payload header first byte:
  Z Y W W N C C C
  - Z: scalability structure present (0 for now)
  - Y: start of OBU (or first fragment)
  - W: fragmentation state (0=not fragmented, 1=first, 2=middle, 3=last)
  - N: non-reference (0 for now)
  - C: count/marker (we use it to store number of aggregated OBUs, capped at 7)
  """
  import Bitwise

  @type w_value :: 0..3
  @type c_value :: 0..7
  @type t :: %__MODULE__{
          z: boolean(),
          y: boolean(),
          w: w_value(),
          n: boolean(),
          c: c_value()
        }
  defstruct z: false, y: false, w: 0, n: false, c: 0

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{z: z, y: y, w: w, n: n, c: c})
      when is_boolean(z) and is_boolean(y) and w in 0..3 and is_boolean(n) and c in 0..7 do
    zbit = if z, do: 1, else: 0
    ybit = if y, do: 1, else: 0
    nbit = if n, do: 1, else: 0
    <<zbit <<< 7 ||| ybit <<< 6 ||| w <<< 4 ||| nbit <<< 3 ||| c>>
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | :error
  def decode(<<byte, rest::binary>>) do
    z = (byte &&& 0b1000_0000) != 0
    y = (byte &&& 0b0100_0000) != 0
    w = (byte &&& 0b0011_0000) >>> 4
    n = (byte &&& 0b0000_1000) != 0
    c = byte &&& 0b0000_0111
    {:ok, %__MODULE__{z: z, y: y, w: w, n: n, c: c}, rest}
  end

  def decode(_), do: :error
end
