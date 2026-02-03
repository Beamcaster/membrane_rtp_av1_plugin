defmodule Membrane.RTP.AV1.LEB128 do
  @moduledoc """
  Utilities for handling unsigned Little Endian Base 128 (LEB128) integers.

  LEB128 is a variable-length encoding for integers used extensively in the AV1
  bitstream format. This module provides functions for encoding integers to LEB128
  format and reading LEB128-encoded values from binary data.

  ## Format

  LEB128 encodes integers using 7 bits per byte, with the high bit indicating
  whether more bytes follow:
  - Bit 7 = 0: This is the last byte
  - Bit 7 = 1: More bytes follow
  - Bits 0-6: Data bits (least significant bits first)

  ## Examples

      iex> Membrane.RTP.AV1.LEB128.encode(0)
      <<0>>

      iex> Membrane.RTP.AV1.LEB128.encode(127)
      <<127>>

      iex> Membrane.RTP.AV1.LEB128.encode(128)
      <<128, 1>>

      iex> Membrane.RTP.AV1.LEB128.read(<<128, 1, 99>>)
      {:ok, 2, 128}

  """

  import Bitwise

  @doc """
  Encodes a non-negative integer into LEB128 format.

  ## Parameters

  - `value` - The non-negative integer to encode
  - `acc` - Accumulator for recursive calls (internal use)

  ## Returns

  A binary containing the LEB128-encoded value.

  ## Examples

      iex> Membrane.RTP.AV1.LEB128.encode(0)
      <<0>>

      iex> Membrane.RTP.AV1.LEB128.encode(127)
      <<127>>

      iex> Membrane.RTP.AV1.LEB128.encode(128)
      <<128, 1>>

      iex> Membrane.RTP.AV1.LEB128.encode(300)
      <<172, 2>>

  """
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

  @doc """
  Reads a LEB128-encoded value from binary data.

  ## Parameters

  - `data` - Binary data starting with a LEB128-encoded value
  - `read_bits` - Number of bits already read (internal use)
  - `leb128_size` - Number of bytes consumed so far (internal use)
  - `value` - Accumulated value (internal use)

  ## Returns

  - `{:ok, byte_count, value}` - Successfully decoded value with byte count consumed
  - `{:error, :invalid_leb128_data}` - Invalid or incomplete LEB128 data

  ## Examples

      iex> Membrane.RTP.AV1.LEB128.read(<<0>>)
      {:ok, 1, 0}

      iex> Membrane.RTP.AV1.LEB128.read(<<127>>)
      {:ok, 1, 127}

      iex> Membrane.RTP.AV1.LEB128.read(<<128, 1>>)
      {:ok, 2, 128}

      iex> Membrane.RTP.AV1.LEB128.read(<<172, 2, 99>>)
      {:ok, 2, 300}

  """
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
