defmodule Membrane.RTP.AV1.FormatTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{Format, FMTP}

  doctest Membrane.RTP.AV1.Format

  describe "new/1" do
    test "creates basic format with defaults" do
      format = Format.new()
      assert format.encoding == "AV1"
      assert format.clock_rate == 90_000
      assert format.profile == nil
      assert format.level == nil
      assert format.tier == nil
    end

    test "creates format with all parameters" do
      format = Format.new(profile: 1, level: "5.1", tier: 1, cm: 1)
      assert format.profile == 1
      assert format.level == "5.1"
      assert format.tier == 1
      assert format.cm == 1
    end

    test "creates format with payload type" do
      format = Format.new(payload_type: 96)
      assert format.payload_type == 96
    end
  end

  describe "from_fmtp/1" do
    test "creates format from FMTP struct" do
      fmtp = %FMTP{profile: 0, level_idx: 8, tier: 0}
      format = Format.from_fmtp(fmtp)

      assert format.encoding == "AV1"
      assert format.clock_rate == 90_000
      assert format.profile == 0
      # level_idx 8 -> "4.0"
      assert format.level == "4.0"
      assert format.tier == 0
    end

    test "converts level_idx to level string" do
      fmtp = %FMTP{profile: 1, level_idx: 13}
      format = Format.from_fmtp(fmtp)

      assert format.profile == 1
      # level_idx 13 -> "5.1"
      assert format.level == "5.1"
    end

    test "preserves cm and layer IDs" do
      fmtp = %FMTP{cm: 1, temporal_id: 2, spatial_id: 1}
      format = Format.from_fmtp(fmtp)

      assert format.cm == 1
      assert format.temporal_id == 2
      assert format.spatial_id == 1
    end
  end

  describe "to_fmtp/1" do
    test "converts format to FMTP struct" do
      format = Format.new(profile: 0, level: "4.0", tier: 0)
      fmtp = Format.to_fmtp(format)

      assert fmtp.profile == 0
      # "4.0" -> level_idx 8
      assert fmtp.level_idx == 8
      assert fmtp.tier == 0
    end

    test "converts level string to level_idx" do
      format = Format.new(profile: 1, level: "5.1")
      fmtp = Format.to_fmtp(format)

      assert fmtp.profile == 1
      # "5.1" -> level_idx 13
      assert fmtp.level_idx == 13
    end

    test "preserves cm and layer IDs" do
      format = Format.new(cm: 1, temporal_id: 2, spatial_id: 1)
      fmtp = Format.to_fmtp(format)

      assert fmtp.cm == 1
      assert fmtp.temporal_id == 2
      assert fmtp.spatial_id == 1
    end
  end

  describe "from_sdp/2" do
    test "parses rtpmap only" do
      {:ok, format} = Format.from_sdp("a=rtpmap:96 AV1/90000")

      assert format.encoding == "AV1"
      assert format.clock_rate == 90_000
      assert format.payload_type == 96
      assert format.profile == nil
    end

    test "parses rtpmap and fmtp" do
      {:ok, format} =
        Format.from_sdp(
          "a=rtpmap:96 AV1/90000",
          "a=fmtp:96 profile=0;level-idx=8;tier=0"
        )

      assert format.payload_type == 96
      assert format.profile == 0
      assert format.level == "4.0"
      assert format.tier == 0
    end

    test "parses rtpmap without prefix" do
      {:ok, format} = Format.from_sdp("96 AV1/90000")

      assert format.payload_type == 96
      assert format.encoding == "AV1"
    end

    test "rejects invalid encoding" do
      assert {:error, _} = Format.from_sdp("a=rtpmap:96 H264/90000")
    end

    test "rejects invalid clock rate" do
      assert {:error, _} = Format.from_sdp("a=rtpmap:96 AV1/48000")
    end

    test "rejects invalid fmtp" do
      {:error, _} =
        Format.from_sdp(
          "a=rtpmap:96 AV1/90000",
          "a=fmtp:96 profile=999"
        )
    end
  end

  describe "to_sdp/1" do
    test "generates rtpmap only for minimal format" do
      format = Format.new(payload_type: 96)
      [rtpmap] = Format.to_sdp(format)

      assert rtpmap == "a=rtpmap:96 AV1/90000"
    end

    test "generates rtpmap and fmtp for format with parameters" do
      format = Format.new(payload_type: 96, profile: 0, level: "4.0", tier: 0)
      [rtpmap, fmtp] = Format.to_sdp(format)

      assert rtpmap == "a=rtpmap:96 AV1/90000"
      assert fmtp == "a=fmtp:96 profile=0;level-idx=8;tier=0"
    end

    test "uses default payload type 96 if not specified" do
      format = Format.new(profile: 0)
      [rtpmap, _fmtp] = Format.to_sdp(format)

      assert rtpmap == "a=rtpmap:96 AV1/90000"
    end

    test "includes all parameters in fmtp" do
      format =
        Format.new(
          payload_type: 97,
          profile: 1,
          level: "5.1",
          tier: 1,
          cm: 1,
          temporal_id: 2,
          spatial_id: 1
        )

      [_rtpmap, fmtp] = Format.to_sdp(format)
      assert String.contains?(fmtp, "profile=1")
      assert String.contains?(fmtp, "level-idx=13")
      assert String.contains?(fmtp, "tier=1")
      assert String.contains?(fmtp, "cm=1")
      assert String.contains?(fmtp, "tid=2")
      assert String.contains?(fmtp, "lid=1")
    end
  end

  describe "roundtrip conversions" do
    test "Format -> FMTP -> Format" do
      original = Format.new(profile: 0, level: "4.0", tier: 0, cm: 1)

      fmtp = Format.to_fmtp(original)
      restored = Format.from_fmtp(fmtp)

      assert restored.profile == original.profile
      assert restored.level == original.level
      assert restored.tier == original.tier
      assert restored.cm == original.cm
    end

    test "Format -> SDP -> Format" do
      original = Format.new(payload_type: 96, profile: 1, level: "5.1", tier: 1)

      [rtpmap, fmtp] = Format.to_sdp(original)
      {:ok, restored} = Format.from_sdp(rtpmap, fmtp)

      assert restored.payload_type == original.payload_type
      assert restored.profile == original.profile
      assert restored.level == original.level
      assert restored.tier == original.tier
    end
  end

  describe "level conversions" do
    test "converts all standard level_idx to level strings" do
      test_cases = [
        {0, "2.0"},
        {1, "2.1"},
        {4, "3.0"},
        {5, "3.1"},
        {8, "4.0"},
        {9, "4.1"},
        {12, "5.0"},
        {13, "5.1"},
        {14, "5.2"},
        {15, "5.3"},
        {16, "6.0"},
        {17, "6.1"},
        {18, "6.2"},
        {19, "6.3"},
        {20, "7.0"},
        {21, "7.1"},
        {22, "7.2"},
        {23, "7.3"}
      ]

      for {level_idx, expected_level} <- test_cases do
        fmtp = %FMTP{level_idx: level_idx}
        format = Format.from_fmtp(fmtp)

        assert format.level == expected_level,
               "Expected level_idx #{level_idx} to convert to #{expected_level}, got #{format.level}"
      end
    end

    test "converts all standard level strings to level_idx" do
      test_cases = [
        {"2.0", 0},
        {"2.1", 1},
        {"3.0", 4},
        {"3.1", 5},
        {"4.0", 8},
        {"4.1", 9},
        {"5.0", 12},
        {"5.1", 13},
        {"5.2", 14},
        {"5.3", 15},
        {"6.0", 16},
        {"6.1", 17},
        {"6.2", 18},
        {"6.3", 19},
        {"7.0", 20},
        {"7.1", 21},
        {"7.2", 22},
        {"7.3", 23}
      ]

      for {level, expected_idx} <- test_cases do
        format = Format.new(level: level)
        fmtp = Format.to_fmtp(format)

        assert fmtp.level_idx == expected_idx,
               "Expected level #{level} to convert to level_idx #{expected_idx}, got #{fmtp.level_idx}"
      end
    end

    test "handles nil level gracefully" do
      format = Format.new()
      fmtp = Format.to_fmtp(format)
      assert fmtp.level_idx == nil

      fmtp = %FMTP{}
      format = Format.from_fmtp(fmtp)
      assert format.level == nil
    end

    test "handles invalid level strings" do
      format = Format.new(level: "invalid")
      fmtp = Format.to_fmtp(format)
      assert fmtp.level_idx == nil
    end
  end

  describe "real-world scenarios" do
    test "WebRTC signaling scenario" do
      # Sender creates format
      sender_format =
        Format.new(
          payload_type: 96,
          profile: 0,
          level: "4.0",
          tier: 0
        )

      # Generate SDP offer
      [rtpmap, fmtp] = Format.to_sdp(sender_format)

      # Receiver parses SDP
      {:ok, receiver_format} = Format.from_sdp(rtpmap, fmtp)

      # Verify parameters match
      assert receiver_format.payload_type == 96
      assert receiver_format.profile == 0
      assert receiver_format.level == "4.0"
      assert receiver_format.tier == 0
    end

    test "SFU forwarding scenario with temporal scalability" do
      format =
        Format.new(
          profile: 0,
          level: "5.1",
          temporal_id: 2,
          cm: 1
        )

      # Convert to FMTP for RTP processing
      fmtp = Format.to_fmtp(format)
      assert fmtp.temporal_id == 2
      assert fmtp.cm == 1

      # Reconstruct format
      restored = Format.from_fmtp(fmtp)
      assert restored.temporal_id == 2
      assert restored.cm == 1
    end

    test "Professional streaming with high tier" do
      format =
        Format.new(
          payload_type: 97,
          # Professional
          profile: 2,
          level: "6.3",
          # High tier
          tier: 1
        )

      [rtpmap, fmtp] = Format.to_sdp(format)
      assert rtpmap == "a=rtpmap:97 AV1/90000"
      assert String.contains?(fmtp, "profile=2")
      assert String.contains?(fmtp, "level-idx=19")
      assert String.contains?(fmtp, "tier=1")
    end
  end
end
