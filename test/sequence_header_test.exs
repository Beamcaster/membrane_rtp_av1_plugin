defmodule Membrane.RTP.AV1.SequenceHeaderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Membrane.RTP.AV1.SequenceHeader

  # Build an SH OBU *payload* (post-header byte, post-LEB128-size) per spec
  # §5.5.1. Padding nulls to a byte boundary at the end.
  defp pad(bits) do
    rem_bits = rem(bit_size(bits), 8)
    if rem_bits == 0, do: bits, else: <<bits::bitstring, 0::size(8 - rem_bits)>>
  end

  # Common width/height tail for max_frame_{width,height}_minus_1.
  # n_width=n_height=10 (so frame_width_bits_minus_1=9), values 640-1=639, 360-1=359.
  defp dims_640x360 do
    <<
      9::4,
      9::4,
      639::10,
      359::10
    >>
  end

  describe "parse/1 — libaom-like (regression guard)" do
    test "timing=0, idd=0, 1 op, 640x360" do
      payload =
        pad(<<
          # seq_profile
          0::3,
          # still_picture
          0::1,
          # reduced_still_picture_header
          0::1,
          # timing_info_present_flag
          0::1,
          # initial_display_delay_present_flag
          0::1,
          # operating_points_cnt_minus_1
          0::5,
          # operating_point_idc[0]
          0::12,
          # seq_level_idx[0] (=5, so no seq_tier read)
          5::5,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end
  end

  describe "parse/1 — SVT-like" do
    test "timing=0, idd=1, per-op present, 640x360" do
      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          0::1,
          # initial_display_delay_present_flag
          1::1,
          # operating_points_cnt_minus_1=0
          0::5,
          # operating_point_idc[0]
          0::12,
          # seq_level_idx[0]
          5::5,
          # initial_display_delay_present_for_this_op[0]
          1::1,
          # initial_display_delay_minus_1[0]=0
          0::4,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end

    test "timing=0, idd=1, per-op absent, 1280x720" do
      dims_1280x720 = <<10::4, 10::4, 1279::11, 719::11>>

      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          0::1,
          1::1,
          0::5,
          0::12,
          5::5,
          # per-op idd absent
          0::1,
          dims_1280x720::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 1280, height: 720}}
    end
  end

  describe "parse/1 — timing info branch" do
    test "timing=1, equal_picture_interval=0, decoder_model=0, idd=0" do
      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          # timing_info_present_flag
          1::1,
          # num_units_in_display_tick
          1::32,
          # time_scale
          30::32,
          # equal_picture_interval
          0::1,
          # decoder_model_info_present_flag
          0::1,
          # initial_display_delay_present_flag
          0::1,
          # operating_points_cnt_minus_1
          0::5,
          0::12,
          5::5,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end

    test "timing=1, decoder_model=1, per-op decoder_model_present=1" do
      bdlm1 = 3
      bdl = bdlm1 + 1

      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          1::1,
          1::32,
          30::32,
          0::1,
          # decoder_model_info_present_flag
          1::1,
          # buffer_delay_length_minus_1
          bdlm1::5,
          # num_units_in_decoding_tick
          1::32,
          # buffer_removal_time_length_minus_1
          0::5,
          # frame_presentation_time_length_minus_1
          0::5,
          # initial_display_delay_present_flag
          0::1,
          # operating_points_cnt_minus_1
          0::5,
          0::12,
          5::5,
          # decoder_model_present_for_this_op[0]
          1::1,
          # decoder_buffer_delay[0]
          0::size(bdl),
          # encoder_buffer_delay[0]
          0::size(bdl),
          # low_delay_mode_flag[0]
          0::1,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end
  end

  describe "parse/1 — multiple operating points" do
    test "2 ops, idd=1 with mixed per-op present" do
      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          0::1,
          1::1,
          # operating_points_cnt_minus_1=1 → 2 ops
          1::5,
          # op 0: idc, level, per-op idd present=1, value=5
          0::12,
          5::5,
          1::1,
          5::4,
          # op 1: idc, level, per-op idd absent
          0::12,
          5::5,
          0::1,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end

    test "seq_tier branch fires when seq_level_idx > 7" do
      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          0::1,
          0::1,
          0::5,
          0::12,
          # seq_level_idx=8 → seq_tier (1 bit) is consumed
          8::5,
          # seq_tier
          1::1,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end
  end

  describe "parse/1 — reduced_still_picture_header path" do
    test "reduced=1, 640x360" do
      payload =
        pad(<<
          0::3,
          0::1,
          # reduced_still_picture_header
          1::1,
          # seq_level_idx[0]
          5::5,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end
  end

  describe "parse/1 — uvlc edge case" do
    test "equal_picture_interval=1 with non-trivial uvlc keeps alignment" do
      # uvlc encoding of value=10: leading_zeros=3 (because floor(log2(10+1))=3),
      # actually uvlc is f(leading_zeros 0s) then 1 then f(leading_zeros bits).
      # For value=10: representation is 11-bit "10" prefix... easier: encode 5.
      # value=5: encoded as 0 0 1 0 1 (leading_zeros=2, then 1, then "10" = 2 bits).
      # That's 5 bits total: <<0::1, 0::1, 1::1, 2::2>> = <<0,0,1,1,0>> bits.
      uvlc_5 = <<0::1, 0::1, 1::1, 2::2>>

      payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          1::1,
          1::32,
          30::32,
          # equal_picture_interval
          1::1,
          uvlc_5::bitstring,
          0::1,
          0::1,
          0::5,
          0::12,
          5::5,
          dims_640x360()::bitstring
        >>)

      assert SequenceHeader.parse(payload) == {:ok, %{width: 640, height: 360}}
    end
  end

  describe "parse/1 — error paths" do
    test "returns :error on truncated payload" do
      assert SequenceHeader.parse(<<0>>) == :error
    end

    test "returns :error on empty payload" do
      assert SequenceHeader.parse(<<>>) == :error
    end
  end

  describe "extract_from_obu_stream/1" do
    test "finds SH OBU in a size-prefixed OBU stream and parses it" do
      sh_payload =
        pad(<<
          0::3,
          0::1,
          0::1,
          0::1,
          0::1,
          0::5,
          0::12,
          5::5,
          dims_640x360()::bitstring
        >>)

      sh_size = byte_size(sh_payload)

      # OBU header byte: forbidden(0), type=1 (SH), ext=0, has_size=1, reserved(0)
      obu_header = <<0::1, 1::4, 0::1, 1::1, 0::1>>
      size_leb = leb128_encode(sh_size)

      sh_obu =
        <<obu_header::bitstring, size_leb::binary, sh_payload::binary>>

      assert SequenceHeader.extract_from_obu_stream(sh_obu) ==
               {:ok, %{width: 640, height: 360}}
    end

    test "returns :not_found on empty stream" do
      assert SequenceHeader.extract_from_obu_stream(<<>>) == :not_found
    end
  end

  defp leb128_encode(value) when value < 0x80, do: <<value>>

  defp leb128_encode(value) do
    <<0x80 ||| (value &&& 0x7F), leb128_encode(value >>> 7)::binary>>
  end
end
