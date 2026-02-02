defmodule Membrane.RTP.AV1.SDPTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.SDP

  doctest Membrane.RTP.AV1.SDP

  describe "rtpmap/2" do
    test "generates basic rtpmap with default payload type" do
      assert SDP.rtpmap(96) == "a=rtpmap:96 AV1/90000"
    end

    test "generates rtpmap with different payload types" do
      assert SDP.rtpmap(96) == "a=rtpmap:96 AV1/90000"
      assert SDP.rtpmap(97) == "a=rtpmap:97 AV1/90000"
      assert SDP.rtpmap(100) == "a=rtpmap:100 AV1/90000"
      assert SDP.rtpmap(127) == "a=rtpmap:127 AV1/90000"
    end

    test "ignores options (for future extensibility)" do
      assert SDP.rtpmap(96, profile: 0) == "a=rtpmap:96 AV1/90000"
      assert SDP.rtpmap(96, level: "4.0") == "a=rtpmap:96 AV1/90000"
    end

    test "works with payload type 0" do
      assert SDP.rtpmap(0) == "a=rtpmap:0 AV1/90000"
    end
  end

  describe "fmtp/2" do
    test "returns nil for empty options" do
      assert SDP.fmtp(96, []) == nil
    end

    test "generates fmtp with profile only" do
      assert SDP.fmtp(96, profile: 0) == "a=fmtp:96 profile=0"
      assert SDP.fmtp(96, profile: 1) == "a=fmtp:96 profile=1"
      assert SDP.fmtp(96, profile: 2) == "a=fmtp:96 profile=2"
    end

    test "generates fmtp with level only" do
      assert SDP.fmtp(96, level: "4.0") == "a=fmtp:96 level-idx=8"
      assert SDP.fmtp(96, level: "5.1") == "a=fmtp:96 level-idx=13"
      assert SDP.fmtp(96, level: "2.0") == "a=fmtp:96 level-idx=0"
      assert SDP.fmtp(96, level: "7.3") == "a=fmtp:96 level-idx=23"
    end

    test "ignores invalid level strings" do
      assert SDP.fmtp(96, level: "invalid") == nil
      assert SDP.fmtp(96, level: "9.9") == nil
    end

    test "generates fmtp with tier only" do
      assert SDP.fmtp(96, tier: 0) == "a=fmtp:96 tier=0"
      assert SDP.fmtp(96, tier: 1) == "a=fmtp:96 tier=1"
    end

    test "generates fmtp with profile and level" do
      assert SDP.fmtp(96, profile: 0, level: "4.0") == "a=fmtp:96 profile=0;level-idx=8"
      assert SDP.fmtp(96, profile: 1, level: "5.1") == "a=fmtp:96 profile=1;level-idx=13"
    end

    test "generates fmtp with all parameters" do
      assert SDP.fmtp(96, profile: 0, level: "4.0", tier: 0) ==
               "a=fmtp:96 profile=0;level-idx=8;tier=0"

      assert SDP.fmtp(96, profile: 2, level: "5.3", tier: 1) ==
               "a=fmtp:96 profile=2;level-idx=15;tier=1"
    end

    test "generates fmtp with profile and tier" do
      assert SDP.fmtp(96, profile: 1, tier: 1) == "a=fmtp:96 profile=1;tier=1"
    end

    test "generates fmtp with level and tier" do
      assert SDP.fmtp(96, level: "4.0", tier: 0) == "a=fmtp:96 level-idx=8;tier=0"
    end

    test "handles different payload types" do
      assert SDP.fmtp(97, profile: 0) == "a=fmtp:97 profile=0"
      assert SDP.fmtp(100, level: "4.0") == "a=fmtp:100 level-idx=8"
    end

    test "ignores unknown options" do
      assert SDP.fmtp(96, profile: 0, unknown: "value") == "a=fmtp:96 profile=0"
    end

    test "maintains parameter order: profile, level, tier" do
      fmtp = SDP.fmtp(96, tier: 1, level: "4.0", profile: 0)
      assert fmtp == "a=fmtp:96 profile=0;level-idx=8;tier=1"
    end
  end

  describe "generate/2" do
    test "generates rtpmap only when no options provided" do
      assert SDP.generate(96) == ["a=rtpmap:96 AV1/90000"]
      assert SDP.generate(96, []) == ["a=rtpmap:96 AV1/90000"]
    end

    test "generates both rtpmap and fmtp when options provided" do
      result = SDP.generate(96, profile: 0)
      assert result == ["a=rtpmap:96 AV1/90000", "a=fmtp:96 profile=0"]
    end

    test "generates complete SDP with all parameters" do
      result = SDP.generate(96, profile: 0, level: "4.0", tier: 0)

      assert result == [
               "a=rtpmap:96 AV1/90000",
               "a=fmtp:96 profile=0;level-idx=8;tier=0"
             ]
    end

    test "generates for different payload types" do
      result = SDP.generate(100, profile: 1, level: "5.1")

      assert result == [
               "a=rtpmap:100 AV1/90000",
               "a=fmtp:100 profile=1;level-idx=13"
             ]
    end

    test "generates rtpmap only when options don't produce fmtp" do
      assert SDP.generate(96, level: "invalid") == ["a=rtpmap:96 AV1/90000"]
    end
  end

  describe "clock_rate/0" do
    test "returns 90000" do
      assert SDP.clock_rate() == 90_000
    end
  end

  describe "encoding_name/0" do
    test "returns AV1" do
      assert SDP.encoding_name() == "AV1"
    end
  end

  describe "level mapping completeness" do
    test "supports all AV1 levels from 2.0 to 7.3" do
      levels_to_test = [
        {"2.0", 0},
        {"2.3", 3},
        {"3.0", 4},
        {"3.3", 7},
        {"4.0", 8},
        {"4.3", 11},
        {"5.0", 12},
        {"5.3", 15},
        {"6.0", 16},
        {"6.3", 19},
        {"7.0", 20},
        {"7.3", 23}
      ]

      for {level, expected_idx} <- levels_to_test do
        fmtp = SDP.fmtp(96, level: level)

        assert fmtp == "a=fmtp:96 level-idx=#{expected_idx}",
               "Level #{level} should map to level-idx=#{expected_idx}"
      end
    end
  end

  describe "real-world SDP examples" do
    test "generates SDP for typical WebRTC scenario" do
      result = SDP.generate(96, profile: 0, level: "4.0", tier: 0)

      assert result == [
               "a=rtpmap:96 AV1/90000",
               "a=fmtp:96 profile=0;level-idx=8;tier=0"
             ]
    end

    test "generates SDP for high-quality streaming" do
      result = SDP.generate(97, profile: 1, level: "5.1", tier: 0)

      assert result == [
               "a=rtpmap:97 AV1/90000",
               "a=fmtp:97 profile=1;level-idx=13;tier=0"
             ]
    end

    test "generates minimal SDP for basic use case" do
      result = SDP.generate(96)
      assert result == ["a=rtpmap:96 AV1/90000"]
    end

    test "generates SDP with profile constraint only" do
      result = SDP.generate(96, profile: 0)

      assert result == [
               "a=rtpmap:96 AV1/90000",
               "a=fmtp:96 profile=0"
             ]
    end
  end

  describe "integration with SDP parsing" do
    test "rtpmap format is parseable" do
      rtpmap = SDP.rtpmap(96)
      assert rtpmap =~ ~r/^a=rtpmap:\d+ \w+\/\d+$/
    end

    test "fmtp format is parseable" do
      fmtp = SDP.fmtp(96, profile: 0, level: "4.0", tier: 0)
      assert fmtp =~ ~r/^a=fmtp:\d+ [\w\-]+=[\w\-]+(;[\w\-]+=[\w\-]+)*$/
    end

    test "can extract payload type from rtpmap" do
      rtpmap = SDP.rtpmap(96)
      assert rtpmap =~ ~r/a=rtpmap:96 /
    end

    test "can extract parameters from fmtp" do
      fmtp = SDP.fmtp(96, profile: 0, level: "4.0")
      assert fmtp =~ ~r/profile=0/
      assert fmtp =~ ~r/level-idx=8/
    end
  end
end
