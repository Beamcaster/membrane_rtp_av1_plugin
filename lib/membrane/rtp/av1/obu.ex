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
  Splits a Low Overhead Bitstream Format access unit into OBUs.

  Each OBU has `obu_has_size_field=1` with size embedded in the OBU header itself,
  rather than external LEB128 length prefixes.

  This is the format output by depayloaders for temporal units.

  If parsing fails at any point, returns a single-element list containing the original binary.
  """
  @spec split_obus_low_overhead(binary()) :: [binary()]
  def split_obus_low_overhead(data) when is_binary(data) do
    do_split_low_overhead(data, [])
  end

  defp do_split_low_overhead(<<>>, acc), do: Enum.reverse(acc)

  defp do_split_low_overhead(data, acc) do
    case parse_obu_with_internal_size(data) do
      {:ok, obu_binary, rest} ->
        do_split_low_overhead(rest, [obu_binary | acc])

      :error ->
        # Fallback: return accumulated OBUs plus remaining data
        if acc == [], do: [data], else: Enum.reverse([data | acc])
    end
  end

  # Parses a single OBU in Low Overhead Bitstream Format (obu_has_size_field=1)
  defp parse_obu_with_internal_size(<<header::8, rest::binary>> = data) do
    # OBU header format (AV1 spec section 5.3.1):
    # - obu_forbidden_bit (1 bit) - must be 0
    # - obu_type (4 bits) - valid types are 1-8
    # - obu_extension_flag (1 bit)
    # - obu_has_size_field (1 bit)
    # - obu_reserved_1bit (1 bit) - must be 0
    forbidden = header >>> 7
    obu_type = header >>> 3 &&& 0x0F
    has_extension = (header &&& 0x04) != 0
    has_size = (header &&& 0x02) != 0
    reserved_bit = header &&& 0x01

    # Reject invalid OBUs:
    # - forbidden bit must be 0
    # - obu_type must be valid (1-8)
    # - reserved bit must be 0
    unless forbidden == 0 and obu_type in 1..8 and reserved_bit == 0 do
      :error
    else
      # Calculate header size (1 byte + optional extension byte)
      {rest_after_header, header_bytes} =
        if has_extension do
          case rest do
            <<_ext::8, r::binary>> -> {r, 2}
            _ -> {rest, 1}
          end
        else
          {rest, 1}
        end

      if has_size do
        # Read LEB128 size field embedded in OBU
        case leb128_decode_prefix(rest_after_header) do
          {:ok, {payload_size, leb_bytes, _rest_after_leb}} ->
            leb_size = byte_size(leb_bytes)
            total_obu_size = header_bytes + leb_size + payload_size

            if total_obu_size <= byte_size(data) do
              <<obu::binary-size(total_obu_size), remaining::binary>> = data
              {:ok, obu, remaining}
            else
              :error
            end

          :error ->
            :error
        end
      else
        # No size field - this OBU consumes rest of data
        # This is rare but valid (e.g., temporal delimiter without size field)
        {:ok, data, <<>>}
      end
    end
  end

  defp parse_obu_with_internal_size(_), do: :error

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
    value = acc ||| (byte &&& 0x7F) <<< shift
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

  @doc """
  Strips the internal size field from an OBU and returns the OBU data
  with obu_has_size_field=0, as required by RFC 9420.

  Input: OBU with obu_has_size_field=1 (Low Overhead format)
  Output: OBU with obu_has_size_field=0 (RTP format)

  Returns {:ok, obu_without_size} or :error.
  """
  @spec strip_obu_size_field(binary()) :: {:ok, binary()} | :error
  def strip_obu_size_field(<<header::8, rest::binary>>) do
    # OBU header format:
    # - obu_forbidden_bit (1 bit)
    # - obu_type (4 bits)
    # - obu_extension_flag (1 bit)
    # - obu_has_size_field (1 bit)
    # - obu_reserved_1bit (1 bit)
    has_extension = (header &&& 0x04) != 0
    has_size = (header &&& 0x02) != 0

    # Clear the obu_has_size_field bit
    new_header = header &&& 0xFD

    if has_size do
      # Skip extension byte if present
      {rest_after_ext, ext_byte} =
        if has_extension do
          case rest do
            <<ext::8, r::binary>> -> {r, <<ext::8>>}
            _ -> {rest, <<>>}
          end
        else
          {rest, <<>>}
        end

      # Read and skip the LEB128 size field
      case leb128_decode_prefix(rest_after_ext) do
        {:ok, {_size, _leb_bytes, obu_payload}} ->
          # Reconstruct OBU: new_header + extension (if any) + payload (no size field)
          {:ok, <<new_header::8>> <> ext_byte <> obu_payload}

        :error ->
          :error
      end
    else
      # No size field to strip
      {:ok, <<new_header::8, rest::binary>>}
    end
  end

  def strip_obu_size_field(_), do: :error

  @doc """
  Converts an OBU to RTP OBU element format with LEB128 length prefix.

  Input: OBU with obu_has_size_field=1 (Low Overhead format)
  Output: LEB128 length prefix + OBU with obu_has_size_field=0 (RTP format)

  This is used for all but the last OBU in an RTP packet with W>0.

  Returns {:ok, rtp_obu_element} or :error.
  """
  @spec to_rtp_obu_element_with_size(binary()) :: {:ok, binary()} | :error
  def to_rtp_obu_element_with_size(obu) do
    case strip_obu_size_field(obu) do
      {:ok, obu_without_size} ->
        size = byte_size(obu_without_size)
        leb = leb128_encode(size)
        {:ok, leb <> obu_without_size}

      :error ->
        :error
    end
  end

  @doc """
  Converts an OBU to RTP OBU element format WITHOUT length prefix.

  Input: OBU with obu_has_size_field=1 (Low Overhead format)
  Output: OBU with obu_has_size_field=0 (RTP format, no length prefix)

  This is used for the last OBU in an RTP packet with W>0.

  Returns {:ok, rtp_obu_element} or :error.
  """
  @spec to_rtp_obu_element(binary()) :: {:ok, binary()} | :error
  def to_rtp_obu_element(obu) do
    strip_obu_size_field(obu)
  end
end
