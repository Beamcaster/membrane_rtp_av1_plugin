defmodule Membrane.RTP.AV1.Header do
  @moduledoc """
  Minimal AV1 RTP payload header (non-spec, draft-aligned concept):

  Uses 1 byte:
  - S: start of OBU fragment group (1 bit)
  - E: end of OBU fragment group (1 bit)
  - F: packet carries fragmented OBU data (1 bit)
  - C: number of complete OBUs aggregated in this packet (5 bits)

  This aims to be forward-compatible with spec ideas (start/end markers and aggregation count),
  but is intentionally simplified for initial implementation.
  """
  import Bitwise

  @type t :: %__MODULE__{
          start?: boolean(),
          end?: boolean(),
          fragmented?: boolean(),
          obu_count: 0..31
        }
  defstruct start?: false, end?: false, fragmented?: false, obu_count: 0

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{start?: s, end?: e, fragmented?: f, obu_count: c})
      when is_boolean(s) and is_boolean(e) and is_boolean(f) and c in 0..31 do
    sbit = if s, do: 1, else: 0
    ebit = if e, do: 1, else: 0
    fbit = if f, do: 1, else: 0
    <<(sbit <<< 7) ||| (ebit <<< 6) ||| (fbit <<< 5) ||| c>>
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | :error
  def decode(<<byte, rest::binary>>) do
    s = (byte &&& 0b1000_0000) != 0
    e = (byte &&& 0b0100_0000) != 0
    f = (byte &&& 0b0010_0000) != 0
    c = byte &&& 0b0001_1111
    {:ok, %__MODULE__{start?: s, end?: e, fragmented?: f, obu_count: c}, rest}
  end

  def decode(_), do: :error

  import Bitwise
end
