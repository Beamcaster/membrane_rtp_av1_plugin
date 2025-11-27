defmodule Membrane.RTP.AV1.SequenceDetector do
  @moduledoc """
  Detects AV1 sequence headers in access units for N bit generation.

  The N bit in RTP aggregation headers MUST be set to 1 for the first packet
  of a coded video sequence (typically keyframes with sequence headers).

  This module provides utilities to detect the presence of sequence header OBUs
  in AV1 access units, enabling automatic N bit generation during payloading.
  """

  import Bitwise
  alias Membrane.RTP.AV1.ExWebRTC.LEB128

  @obu_sequence_header 1

  @doc """
  Checks if an access unit contains a sequence header OBU.

  Returns `true` if a sequence header (OBU type 1) is found, `false` otherwise.

  ## Examples

      iex> access_unit = <<...>>  # Access unit with sequence header
      iex> SequenceDetector.contains_sequence_header?(access_unit)
      true

      iex> delta_frame = <<...>>  # Delta frame without sequence header
      iex> SequenceDetector.contains_sequence_header?(delta_frame)
      false
  """
  @spec contains_sequence_header?(binary()) :: boolean()
  def contains_sequence_header?(access_unit) when is_binary(access_unit) do
    extract_sequence_header(access_unit) != nil
  end

  @doc """
  Extracts the sequence header OBU from an access unit if present.

  Returns the complete sequence header OBU (including header and payload) or `nil`.

  ## Examples

      iex> access_unit = <<...>>
      iex> SequenceDetector.extract_sequence_header(access_unit)
      <<...>>  # Sequence header OBU binary

      iex> SequenceDetector.extract_sequence_header(<<>>)
      nil
  """
  @spec extract_sequence_header(binary()) :: binary() | nil
  def extract_sequence_header(data) when is_binary(data) do
    find_obu_by_type(data, @obu_sequence_header)
  end

  # Private helpers

  # Find and extract a specific OBU type from data
  defp find_obu_by_type(data, target_type) when is_binary(data) do
    find_obu_by_type_impl(data, target_type)
  end

  defp find_obu_by_type_impl(<<>>, _target_type), do: nil

  defp find_obu_by_type_impl(data, target_type) do
    case get_obu_total_size(data) do
      {:ok, total_size} when total_size > 0 and total_size <= byte_size(data) ->
        <<obu_data::binary-size(total_size), rest::binary>> = data

        case parse_obu_header(obu_data) do
          {:ok, %{type: ^target_type}} ->
            obu_data

          {:ok, _} ->
            find_obu_by_type_impl(rest, target_type)

          {:error, _} ->
            nil
        end

      _ ->
        nil
    end
  end

  # Parse OBU header and return structured information
  defp parse_obu_header(<<header::8, rest::binary>>) do
    # OBU header format (AV1 spec section 5.3.1):
    # - obu_forbidden_bit (1 bit) - must be 0
    # - obu_type (4 bits)
    # - obu_extension_flag (1 bit)
    # - obu_has_size_field (1 bit)
    # - obu_reserved_1bit (1 bit)

    forbidden_bit = header >>> 7
    obu_type = (header >>> 3) &&& 0x0F
    has_extension = (header &&& 0x04) != 0
    has_size = (header &&& 0x02) != 0

    if forbidden_bit != 0 do
      {:error, :forbidden_bit_set}
    else
      # Handle extension header if present
      {rest_after_ext, extension_bytes} =
        if has_extension do
          case rest do
            <<_ext_header::8, r::binary>> -> {r, 1}
            _ -> {rest, 0}
          end
        else
          {rest, 0}
        end

      {:ok,
       %{
         type: obu_type,
         has_size: has_size,
         has_extension: has_extension,
         header_bytes: 1 + extension_bytes,
         rest: rest_after_ext
       }}
    end
  end

  defp parse_obu_header(<<>>), do: {:error, :empty_data}
  defp parse_obu_header(_), do: {:error, :invalid_data}

  # Get total OBU size (header + size field + payload)
  defp get_obu_total_size(data) do
    case parse_obu_header(data) do
      {:ok, obu_info} ->
        if obu_info.has_size do
          case read_obu_size(obu_info.rest) do
            {:ok, payload_size, size_bytes} ->
              {:ok, obu_info.header_bytes + size_bytes + payload_size}

            {:error, _} = err ->
              err
          end
        else
          # OBU without size field - assume rest of data
          # This is rare in RTP payloads but handle it
          {:ok, byte_size(data)}
        end

      {:error, _} = err ->
        err
    end
  end

  # Read OBU size using LEB128 encoding
  defp read_obu_size(data) do
    case LEB128.read(data) do
      {:ok, size_bytes, value} -> {:ok, value, size_bytes}
      {:error, reason} -> {:error, reason}
    end
  end
end
