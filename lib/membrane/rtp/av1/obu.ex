defmodule Membrane.RTP.AV1.OBU do
  @moduledoc """
  Helpers for working with AV1 OBUs using length-delimited (LEB128) framing.
  """
  import Bitwise

  @doc """
  Splits a length-delimited access unit into a list of complete OBUs (including their LEB128 length headers).

  If parsing fails at any point, returns a single-element list containing the original binary.
  """
  @spec split_obus(binary()) :: [binary()]
  def split_obus(access_unit) when is_binary(access_unit) do
    do_split(access_unit, [])
  end

  defp do_split(<<>>, acc), do: Enum.reverse(acc)

  defp do_split(binary, acc) do
    with {:ok, {len, leb_bytes, rest_after_leb}} <- leb128_decode_prefix(binary),
         true <- byte_size(rest_after_leb) >= len do
      <<obu_payload::binary-size(len), rest::binary>> = rest_after_leb
      obu = leb_bytes <> obu_payload
      do_split(rest, [obu | acc])
    else
      _ -> [binary]
    end
  end

  @doc """
  Encodes an OBU given its raw payload by prefixing it with a LEB128 length.
  """
  @spec build_obu(binary()) :: binary()
  def build_obu(payload) when is_binary(payload) do
    leb = leb128_encode(byte_size(payload))
    leb <> payload
  end

  @doc """
  Decodes a LEB128 length from the beginning of the binary.

  Returns {:ok, {value, leb_prefix_binary, rest}} or :error.
  """
  @spec leb128_decode_prefix(binary()) :: {:ok, {non_neg_integer(), binary(), binary()}} | :error
  def leb128_decode_prefix(binary) when is_binary(binary) do
    do_leb128_decode(binary, 0, 0, [])
  end

  defp do_leb128_decode(<<>>, _shift, _acc, _bytes), do: :error

  defp do_leb128_decode(<<byte, rest::binary>>, shift, acc, bytes) do
    value = acc ||| ((byte &&& 0x7F) <<< shift)
    bytes_acc = [byte | bytes]
    if (byte &&& 0x80) == 0 do
      leb = bytes_acc |> Enum.reverse() |> :erlang.list_to_binary()
      {:ok, {value, leb, rest}}
    else
      do_leb128_decode(rest, shift + 7, value, bytes_acc)
    end
  end

  @doc """
  Encodes a non-negative integer using unsigned LEB128.
  """
  @spec leb128_encode(non_neg_integer()) :: binary()
  def leb128_encode(value) when is_integer(value) and value >= 0 do
    do_leb128_encode(value, [])
  end

  defp do_leb128_encode(value, acc) when value < 0x80 do
    acc = [value | acc] |> Enum.reverse()
    :erlang.list_to_binary(acc)
  end

  defp do_leb128_encode(value, acc) do
    byte = bor(band(value, 0x7F), 0x80)
    do_leb128_encode(value >>> 7, [byte | acc])
  end
end
