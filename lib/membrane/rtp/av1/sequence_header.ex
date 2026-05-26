defmodule Membrane.RTP.AV1.SequenceHeader do
  @moduledoc """
  Parses an AV1 Sequence Header OBU payload and extracts the codec parameters
  that downstream Membrane elements need (notably `:width` and `:height`,
  required by `Membrane.MP4.Muxer.ISOM` to serialize the `tkhd` box).

  Pass the **OBU payload** (i.e. the OBU body after the OBU header byte,
  optional extension byte, and optional LEB128 size field) to `parse/1`.
  Helper `extract_from_obu_stream/1` walks an OBU stream — a concatenation
  of size-prefixed OBUs as emitted by the depayloader — and runs `parse/1`
  on the first Sequence Header OBU found.

  Implements the relevant prefix of `sequence_header_obu()` per AV1 spec
  section 5.5.1.
  """

  import Bitwise

  @obu_sequence_header 1

  @type parsed :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer()
        }

  @doc """
  Parse a Sequence Header OBU payload and return its dimensions.

  Returns `{:ok, %{width: w, height: h}}` on success or `:error` if the
  binary is truncated or malformed.
  """
  @spec parse(binary()) :: {:ok, parsed()} | :error
  def parse(payload) when is_binary(payload) do
    try do
      bits = bitstream(payload)

      {_seq_profile, bits} = take_bits(bits, 3)
      {_still_picture, bits} = take_bits(bits, 1)
      {reduced_still_picture_header, bits} = take_bits(bits, 1)

      bits = skip_through_operating_points(bits, reduced_still_picture_header)

      {frame_width_bits_minus_1, bits} = take_bits(bits, 4)
      {frame_height_bits_minus_1, bits} = take_bits(bits, 4)

      n_width = frame_width_bits_minus_1 + 1
      n_height = frame_height_bits_minus_1 + 1

      {max_frame_width_minus_1, bits} = take_bits(bits, n_width)
      {max_frame_height_minus_1, _bits} = take_bits(bits, n_height)

      {:ok, %{width: max_frame_width_minus_1 + 1, height: max_frame_height_minus_1 + 1}}
    rescue
      _ -> :error
    catch
      _ -> :error
    end
  end

  @doc """
  Walks an OBU stream (concatenated size-prefixed OBUs, as emitted by the
  depayloader) looking for a Sequence Header OBU. Returns the same shape
  as `parse/1` on success or `:not_found` if no parseable SH OBU is in the
  stream.
  """
  @spec extract_from_obu_stream(binary()) :: {:ok, parsed()} | :not_found
  def extract_from_obu_stream(binary) when is_binary(binary), do: walk_obus(binary)

  defp walk_obus(<<>>), do: :not_found

  defp walk_obus(<<byte0, rest::binary>>) do
    <<_forbidden::1, obu_type::4, extension_flag::1, has_size_flag::1, _reserved::1>> = <<byte0>>

    rest =
      if extension_flag == 1 do
        case rest do
          <<_ext, tail::binary>> -> tail
          _ -> <<>>
        end
      else
        rest
      end

    case extract_obu_payload(rest, has_size_flag) do
      {:ok, obu_payload, tail} ->
        if obu_type == @obu_sequence_header do
          case parse(obu_payload) do
            {:ok, _} = ok -> ok
            :error -> walk_obus(tail)
          end
        else
          walk_obus(tail)
        end

      :error ->
        :not_found
    end
  end

  defp extract_obu_payload(rest, 1) do
    case read_leb128(rest) do
      {:ok, size, after_size} ->
        case after_size do
          <<obu_payload::binary-size(size), tail::binary>> -> {:ok, obu_payload, tail}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp extract_obu_payload(rest, 0), do: {:ok, rest, <<>>}

  defp read_leb128(binary), do: read_leb128(binary, 0, 0)

  defp read_leb128(<<>>, _shift, _acc), do: :error
  defp read_leb128(_binary, shift, _acc) when shift > 56, do: :error

  defp read_leb128(<<byte, rest::binary>>, shift, acc) do
    value = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      read_leb128(rest, shift + 7, value)
    end
  end

  defp skip_through_operating_points(bits, 1) do
    # reduced_still_picture_header path: just seq_level_idx[0] (5 bits).
    # operating_points_cnt_minus_1 is implied 0; no per-op extras.
    {_, bits} = take_bits(bits, 5)
    bits
  end

  defp skip_through_operating_points(bits, 0) do
    {timing_info_present_flag, bits} = take_bits(bits, 1)

    {decoder_model_info_present_flag, buffer_delay_length_minus_1, bits} =
      if timing_info_present_flag == 1 do
        skip_timing_and_decoder_model(bits)
      else
        # Spec §5.5.1: decoder_model_info_present_flag is implicitly 0 when
        # timing_info_present_flag is 0 — NO bit is consumed here.
        {0, 0, bits}
      end

    {initial_display_delay_present_flag, bits} = take_bits(bits, 1)
    {operating_points_cnt_minus_1, bits} = take_bits(bits, 5)

    skip_operating_points(
      bits,
      operating_points_cnt_minus_1 + 1,
      decoder_model_info_present_flag,
      buffer_delay_length_minus_1,
      initial_display_delay_present_flag
    )
  end

  # Returns {decoder_model_info_present_flag, buffer_delay_length_minus_1, bits}
  defp skip_timing_and_decoder_model(bits) do
    # num_units_in_display_tick (32) + time_scale (32)
    {_, bits} = take_bits(bits, 32)
    {_, bits} = take_bits(bits, 32)
    {equal_picture_interval, bits} = take_bits(bits, 1)
    bits = if equal_picture_interval == 1, do: skip_uvlc(bits), else: bits

    {decoder_model_info_present_flag, bits} = take_bits(bits, 1)

    if decoder_model_info_present_flag == 1 do
      # decoder_model_info():
      #   buffer_delay_length_minus_1            (5)
      #   num_units_in_decoding_tick             (32)
      #   buffer_removal_time_length_minus_1     (5)
      #   frame_presentation_time_length_minus_1 (5)
      {buffer_delay_length_minus_1, bits} = take_bits(bits, 5)
      {_, bits} = take_bits(bits, 32 + 5 + 5)
      {1, buffer_delay_length_minus_1, bits}
    else
      {0, 0, bits}
    end
  end

  # uvlc — variable-length unsigned. Read leading 0 bits, then 1, then
  # leading_zeros bits of value (which we discard). Per spec, leading_zeros
  # can be up to 32; at exactly 32 the value is still 32 bits and MUST be
  # consumed before returning, otherwise every later read is misaligned.
  defp skip_uvlc(bits), do: skip_uvlc(bits, 0)

  defp skip_uvlc(bits, 32) do
    {_, bits} = take_bits(bits, 32)
    bits
  end

  defp skip_uvlc(bits, leading_zeros) do
    {bit, bits} = take_bits(bits, 1)

    if bit == 1 do
      {_, bits} = take_bits(bits, leading_zeros)
      bits
    else
      skip_uvlc(bits, leading_zeros + 1)
    end
  end

  defp skip_operating_points(bits, 0, _dmi, _bdlm1, _iddp), do: bits

  defp skip_operating_points(bits, n, dmi, bdlm1, iddp) do
    {_operating_point_idc, bits} = take_bits(bits, 12)
    {seq_level_idx, bits} = take_bits(bits, 5)

    bits =
      if seq_level_idx > 7 do
        {_seq_tier, bits} = take_bits(bits, 1)
        bits
      else
        bits
      end

    bits = skip_per_op_decoder_model(bits, dmi, bdlm1)
    bits = skip_per_op_initial_display_delay(bits, iddp)

    skip_operating_points(bits, n - 1, dmi, bdlm1, iddp)
  end

  defp skip_per_op_decoder_model(bits, 0, _bdlm1), do: bits

  defp skip_per_op_decoder_model(bits, 1, bdlm1) do
    {present_for_this_op, bits} = take_bits(bits, 1)

    if present_for_this_op == 1 do
      # operating_parameters_info(op):
      #   decoder_buffer_delay[op]  (buffer_delay_length_minus_1 + 1 bits)
      #   encoder_buffer_delay[op]  (same)
      #   low_delay_mode_flag[op]   (1 bit)
      bdl = bdlm1 + 1
      {_, bits} = take_bits(bits, bdl + bdl + 1)
      bits
    else
      bits
    end
  end

  defp skip_per_op_initial_display_delay(bits, 0), do: bits

  defp skip_per_op_initial_display_delay(bits, 1) do
    {present_for_this_op, bits} = take_bits(bits, 1)

    if present_for_this_op == 1 do
      {_initial_display_delay_minus_1, bits} = take_bits(bits, 4)
      bits
    else
      bits
    end
  end

  # Bitstream helpers — operate on {offset, binary} where offset is the
  # number of leading bits in the binary already consumed.

  defp bitstream(binary), do: {0, binary}

  defp take_bits({offset, binary}, count) do
    if offset + count > bit_size(binary), do: throw(:short)
    <<_::size(offset), value::size(count), _::bitstring>> = binary
    {value, {offset + count, binary}}
  end
end
