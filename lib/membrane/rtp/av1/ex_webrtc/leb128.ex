defmodule Membrane.RTP.AV1.ExWebRTC.LEB128 do
  @moduledoc false
  # Utilities for handling unsigned Little Endian Base 128 integers
  # Adapted from ExWebRTC.RTP.AV1.LEB128

  import Bitwise

  @spec encode(non_neg_integer(), [bitstring()]) :: binary()
  def encode(value, acc \\ [])

  def encode(value, acc) when value < 0x80 do
    for group <- Enum.reverse([value | acc]), into: <<>> do
      <<group>>
    end
  end

  def encode(value, acc) do
    group = 0x80 ||| (value &&& 0x7F)
    encode(value >>> 7, [group | acc])
  end

  @spec read(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, pos_integer(), non_neg_integer()} | {:error, :invalid_leb128_data}
  def read(data, read_bits \\ 0, leb128_size \\ 0, value \\ 0)

  def read(<<0::1, group::7, _rest::binary>>, read_bits, leb128_size, value) do
    {:ok, leb128_size + 1, value ||| group <<< read_bits}
  end

  def read(<<1::1, group::7, rest::binary>>, read_bits, leb128_size, value) do
    read(rest, read_bits + 7, leb128_size + 1, value ||| group <<< read_bits)
  end

  def read(_, _, _, _), do: {:error, :invalid_leb128_data}
end
