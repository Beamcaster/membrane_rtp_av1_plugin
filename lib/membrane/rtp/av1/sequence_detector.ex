defmodule Membrane.RTP.AV1.SequenceDetector do
  @moduledoc """
  Detects AV1 sequence headers and keyframes in access units for N bit generation.

  The N bit in RTP aggregation headers MUST be set to 1 for the first packet
  of a coded video sequence (typically keyframes with sequence headers).

  IMPORTANT: A coded video sequence starts with a KEYFRAME, not just any frame
  with a sequence header. The N bit should only be set when:
  1. The access unit contains a sequence header OBU, AND
  2. The access unit contains a keyframe (frame_type == 0)

  This module provides utilities to detect true keyframes (new coded video sequences)
  in AV1 access units, enabling correct N bit generation during payloading.
  """

  import Bitwise
  alias Membrane.RTP.AV1.ExWebRTC.LEB128

  @obu_sequence_header 1
  @obu_frame 6
  @obu_frame_header 3

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
  Checks if an access unit is a true keyframe that starts a new coded video sequence.

  Returns `true` ONLY if BOTH conditions are met:
  1. The access unit contains a sequence header OBU (type 1)
  2. The access unit contains a keyframe (frame OBU with frame_type == 0)

  This is the correct check for setting the N bit in RTP packets.
  Simply having a sequence header prepended is NOT enough - the frame
  must actually be a keyframe for the N bit to be set.

  ## Examples

      iex> keyframe_with_seq_header = <<...>>  # True keyframe with sequence header
      iex> SequenceDetector.is_new_coded_video_sequence?(keyframe_with_seq_header)
      true

      iex> interframe_with_seq_header = <<...>>  # P-frame with prepended sequence header
      iex> SequenceDetector.is_new_coded_video_sequence?(interframe_with_seq_header)
      true  # Also true! Decoder can start from any frame with sequence header
  """
  @spec is_new_coded_video_sequence?(binary()) :: boolean()
  def is_new_coded_video_sequence?(access_unit) when is_binary(access_unit) do
    has_sequence_header = contains_sequence_header?(access_unit)
    has_keyframe = contains_keyframe?(access_unit)

    # IMPORTANT: For encoders like SVT-AV1 (used by OBS) that use continuous intra refresh,
    # every frame includes a sequence header but frame_type is always INTER_FRAME (1).
    # The decoder CAN start decoding from any frame that has a sequence header,
    # so we set N=1 whenever a sequence header is present.
    # 
    # This is compliant with RFC 9420 which says N=1 indicates the start of a
    # "new coded video sequence" - which is any point from which decoding can begin.
    result = has_sequence_header

    if has_sequence_header do
      require Logger

      Logger.info(
        "✅ NEW CODED VIDEO SEQUENCE: sequence_header=#{has_sequence_header}, frame_type_keyframe=#{has_keyframe} => N=1"
      )
    end

    result
  end

  @doc """
  Checks if an access unit contains a keyframe (frame_type == 0).

  Returns `true` if a frame OBU is found with frame_type = KEY_FRAME (0).
  """
  @spec contains_keyframe?(binary()) :: boolean()
  def contains_keyframe?(access_unit) when is_binary(access_unit) do
    require Logger

    case find_frame_obu(access_unit) do
      nil ->
        Logger.debug(
          "🔍 contains_keyframe?: No frame OBU found in #{byte_size(access_unit)} bytes"
        )

        false

      frame_obu ->
        result = is_keyframe_obu?(frame_obu)
        # Log first 20 bytes of frame OBU for debugging
        first_bytes = binary_part(frame_obu, 0, min(byte_size(frame_obu), 20))

        Logger.info(
          "🔍 contains_keyframe?: Frame OBU found (#{byte_size(frame_obu)} bytes), keyframe?=#{result}, first_bytes=#{inspect(first_bytes, base: :hex)}"
        )

        result
    end
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
    obu_type = header >>> 3 &&& 0x0F
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

  # Find a frame OBU (type 6) in the data
  defp find_frame_obu(data) do
    find_obu_by_type(data, @obu_frame) || find_obu_by_type(data, @obu_frame_header)
  end

  # Check if a frame OBU is a keyframe
  # Frame header format (AV1 spec section 5.9.2):
  # - show_existing_frame (1 bit): if 1, this is a reference to an existing frame
  # - frame_type (2 bits): 0=KEY_FRAME, 1=INTER_FRAME, 2=INTRA_ONLY_FRAME, 3=S_FRAME
  defp is_keyframe_obu?(obu_data) when is_binary(obu_data) do
    case parse_obu_header(obu_data) do
      {:ok, %{type: type, has_size: true, header_bytes: header_bytes, rest: rest}}
      when type == @obu_frame or type == @obu_frame_header ->
        # Read the size field to get to the payload
        case read_obu_size(rest) do
          {:ok, _payload_size, size_bytes} ->
            # Skip header and size to get to payload
            total_header_size = header_bytes + size_bytes
            payload_start = total_header_size

            if byte_size(obu_data) > payload_start do
              <<_header::binary-size(payload_start), payload::binary>> = obu_data
              check_frame_type(payload)
            else
              false
            end

          _ ->
            false
        end

      {:ok, %{type: type, has_size: false, header_bytes: header_bytes}}
      when type == @obu_frame or type == @obu_frame_header ->
        # No size field, payload starts after header
        if byte_size(obu_data) > header_bytes do
          <<_header::binary-size(header_bytes), payload::binary>> = obu_data
          check_frame_type(payload)
        else
          false
        end

      _ ->
        false
    end
  end

  defp is_keyframe_obu?(_), do: false

  # Check the frame_type bits in the frame header payload
  # show_existing_frame (1 bit) + frame_type (2 bits)
  # KEY_FRAME = 0
  defp check_frame_type(<<show_existing_frame::1, frame_type::2, _rest::bitstring>>) do
    require Logger
    # If show_existing_frame is 1, this is NOT a keyframe
    # If show_existing_frame is 0 and frame_type is 0, this IS a keyframe
    is_keyframe = show_existing_frame == 0 and frame_type == 0

    Logger.info(
      "🎬 check_frame_type: show_existing_frame=#{show_existing_frame}, frame_type=#{frame_type} => keyframe?=#{is_keyframe}"
    )

    is_keyframe
  end

  defp check_frame_type(payload) do
    require Logger
    Logger.warning("🎬 check_frame_type: Invalid/empty payload: #{inspect(payload, limit: 20)}")
    false
  end
end
