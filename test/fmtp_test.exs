defmodule Membrane.RTP.AV1.FMTPTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.FMTP
  alias Membrane.RTP.AV1.ScalabilityStructure

  doctest Membrane.RTP.AV1.FMTP

  describe "parse/1 - string parsing" do
    test "parses basic profile parameter" do
      assert {:ok, %FMTP{profile: 0}} = FMTP.parse("profile=0")
      assert {:ok, %FMTP{profile: 1}} = FMTP.parse("profile=1")
      assert {:ok, %FMTP{profile: 2}} = FMTP.parse("profile=2")
    end

    test "parses level-idx parameter" do
      assert {:ok, %FMTP{level_idx: 0}} = FMTP.parse("level-idx=0")
      assert {:ok, %FMTP{level_idx: 8}} = FMTP.parse("level-idx=8")
      assert {:ok, %FMTP{level_idx: 31}} = FMTP.parse("level-idx=31")
    end

    test "parses tier parameter" do
      assert {:ok, %FMTP{tier: 0}} = FMTP.parse("tier=0")
      assert {:ok, %FMTP{tier: 1}} = FMTP.parse("tier=1")
    end

    test "parses cm parameter" do
      assert {:ok, %FMTP{cm: 0}} = FMTP.parse("cm=0")
      assert {:ok, %FMTP{cm: 1}} = FMTP.parse("cm=1")
    end

    test "parses tid (temporal_id) parameter" do
      assert {:ok, %FMTP{temporal_id: 0}} = FMTP.parse("tid=0")
      assert {:ok, %FMTP{temporal_id: 3}} = FMTP.parse("tid=3")
      assert {:ok, %FMTP{temporal_id: 7}} = FMTP.parse("tid=7")
    end

    test "parses lid (spatial_id) parameter" do
      assert {:ok, %FMTP{spatial_id: 0}} = FMTP.parse("lid=0")
      assert {:ok, %FMTP{spatial_id: 2}} = FMTP.parse("lid=2")
      assert {:ok, %FMTP{spatial_id: 3}} = FMTP.parse("lid=3")
    end

    test "parses multiple parameters" do
      assert {:ok, fmtp} = FMTP.parse("profile=0;level-idx=8;tier=0")
      assert fmtp.profile == 0
      assert fmtp.level_idx == 8
      assert fmtp.tier == 0
    end

    test "parses complex combination" do
      assert {:ok, fmtp} = FMTP.parse("profile=1;level-idx=13;tier=1;cm=1;tid=2;lid=1")
      assert fmtp.profile == 1
      assert fmtp.level_idx == 13
      assert fmtp.tier == 1
      assert fmtp.cm == 1
      assert fmtp.temporal_id == 2
      assert fmtp.spatial_id == 1
    end

    test "handles whitespace in parameters" do
      assert {:ok, %FMTP{profile: 0, level_idx: 8}} = FMTP.parse("profile=0 ; level-idx=8")
      assert {:ok, %FMTP{profile: 0}} = FMTP.parse(" profile = 0 ")
    end

    test "returns error for invalid profile" do
      assert {:error, "Invalid profile: 3" <> _} = FMTP.parse("profile=3")
      assert {:error, "Invalid profile: 10" <> _} = FMTP.parse("profile=10")
    end

    test "returns error for invalid level-idx" do
      assert {:error, "Invalid level-idx: 32" <> _} = FMTP.parse("level-idx=32")
      assert {:error, "Invalid level-idx: 100" <> _} = FMTP.parse("level-idx=100")
    end

    test "returns error for invalid tier" do
      assert {:error, "Invalid tier: 2" <> _} = FMTP.parse("tier=2")
    end

    test "returns error for invalid cm" do
      assert {:error, "Invalid cm: 2" <> _} = FMTP.parse("cm=2")
    end

    test "returns error for invalid tid" do
      assert {:error, "Invalid temporal_id: 8" <> _} = FMTP.parse("tid=8")
      assert {:error, "Invalid temporal_id: 15" <> _} = FMTP.parse("tid=15")
    end

    test "returns error for invalid lid" do
      assert {:error, "Invalid spatial_id: 4" <> _} = FMTP.parse("lid=4")
      assert {:error, "Invalid spatial_id: 10" <> _} = FMTP.parse("lid=10")
    end

    test "handles empty string" do
      assert {:ok, %FMTP{}} = FMTP.parse("")
    end

    test "ignores unknown parameters" do
      assert {:ok, fmtp} = FMTP.parse("profile=0;unknown=123")
      assert fmtp.profile == 0
    end
  end

  describe "parse_map/1 - map parsing" do
    test "parses with string keys" do
      assert {:ok, fmtp} = FMTP.parse_map(%{"profile" => "0", "level-idx" => "8"})
      assert fmtp.profile == 0
      assert fmtp.level_idx == 8
    end

    test "parses with atom keys" do
      assert {:ok, fmtp} = FMTP.parse_map(%{profile: 0, level_idx: 8})
      assert fmtp.profile == 0
      assert fmtp.level_idx == 8
    end

    test "parses with integer values" do
      assert {:ok, fmtp} = FMTP.parse_map(%{profile: 1, tier: 1})
      assert fmtp.profile == 1
      assert fmtp.tier == 1
    end

    test "parses with string values" do
      assert {:ok, fmtp} = FMTP.parse_map(%{"profile" => "1", "tier" => "1"})
      assert fmtp.profile == 1
      assert fmtp.tier == 1
    end

    test "handles alternative parameter names" do
      # profile-id as alias for profile
      assert {:ok, %FMTP{profile: 0}} = FMTP.parse_map(%{"profile-id" => "0"})

      # tid as alias for temporal_id
      assert {:ok, %FMTP{temporal_id: 2}} = FMTP.parse_map(%{"tid" => "2"})
      assert {:ok, %FMTP{temporal_id: 2}} = FMTP.parse_map(%{"temporal_id" => "2"})

      # lid as alias for spatial_id
      assert {:ok, %FMTP{spatial_id: 1}} = FMTP.parse_map(%{"lid" => "1"})
      assert {:ok, %FMTP{spatial_id: 1}} = FMTP.parse_map(%{"spatial_id" => "1"})
    end

    test "returns error for invalid values" do
      assert {:error, "Invalid profile:" <> _} = FMTP.parse_map(%{profile: 5})
      assert {:error, "Invalid level-idx:" <> _} = FMTP.parse_map(%{level_idx: 50})
      assert {:error, "Invalid tier:" <> _} = FMTP.parse_map(%{tier: 3})
    end

    test "handles empty map" do
      assert {:ok, %FMTP{}} = FMTP.parse_map(%{})
    end
  end

  describe "validation - parameter combinations" do
    test "allows tier 0 with profile 0 (Main)" do
      assert {:ok, fmtp} = FMTP.parse("profile=0;tier=0")
      assert fmtp.profile == 0
      assert fmtp.tier == 0
    end

    test "rejects tier 1 with profile 0 (Main)" do
      assert {:error, "Profile 0 (Main) only supports tier 0"} = FMTP.parse("profile=0;tier=1")
    end

    test "allows tier 1 with profile 1 (High)" do
      assert {:ok, fmtp} = FMTP.parse("profile=1;tier=1")
      assert fmtp.profile == 1
      assert fmtp.tier == 1
    end

    test "allows tier 1 with profile 2 (Professional)" do
      assert {:ok, fmtp} = FMTP.parse("profile=2;tier=1")
      assert fmtp.profile == 2
      assert fmtp.tier == 1
    end

    test "allows tier without level-idx" do
      # tier can indicate preference without strict constraint
      assert {:ok, fmtp} = FMTP.parse("profile=1;tier=1")
      assert fmtp.tier == 1
      assert fmtp.level_idx == nil
    end

    test "allows tier with level-idx" do
      assert {:ok, fmtp} = FMTP.parse("profile=1;level-idx=13;tier=1")
      assert fmtp.profile == 1
      assert fmtp.level_idx == 13
      assert fmtp.tier == 1
    end

    test "allows profile without level-idx" do
      assert {:ok, %FMTP{profile: 0}} = FMTP.parse("profile=0")
    end

    test "allows level-idx without tier" do
      assert {:ok, fmtp} = FMTP.parse("level-idx=8")
      assert fmtp.level_idx == 8
      assert fmtp.tier == nil
    end
  end

  describe "scalability structure parsing" do
    test "parses ss-data hex string" do
      # Create a valid SS structure
      ss = ScalabilityStructure.simple(1, 1)
      {:ok, ss_binary} = ScalabilityStructure.encode(ss)
      ss_hex = Base.encode16(ss_binary)

      assert {:ok, fmtp} = FMTP.parse_map(%{"ss-data" => ss_hex})
      assert %ScalabilityStructure{} = fmtp.scalability_structure
      # Just verify we got a valid structure back
      assert is_integer(fmtp.scalability_structure.n_s)
      assert is_boolean(fmtp.scalability_structure.y_flag)
    end

    test "handles invalid ss-data hex" do
      assert {:error, "Invalid ss-data hex encoding"} = FMTP.parse_map(%{"ss-data" => "ZZZZ"})
    end

    test "handles malformed ss-data binary" do
      # Invalid binary that can't be decoded as SS
      invalid_hex = Base.encode16(<<0xFF, 0xFF, 0xFF>>)
      assert {:error, "Invalid ss-data:" <> _} = FMTP.parse_map(%{"ss-data" => invalid_hex})
    end

    test "accepts ScalabilityStructure struct directly" do
      ss = ScalabilityStructure.simple(2, 1)
      assert {:ok, fmtp} = FMTP.parse_map(%{ss: ss})
      assert fmtp.scalability_structure == ss
    end

    test "handles both ss and ss-data" do
      # Direct struct takes precedence
      ss = ScalabilityStructure.simple(2, 1)
      ss2 = ScalabilityStructure.simple(1, 1)
      {:ok, ss2_binary} = ScalabilityStructure.encode(ss2)
      ss_hex = Base.encode16(ss2_binary)

      assert {:ok, fmtp} = FMTP.parse_map(%{"ss-data" => ss_hex, ss: ss})
      assert fmtp.scalability_structure == ss
    end
  end

  describe "parse_legacy/1 - backward compatibility" do
    test "returns struct directly for valid parameters" do
      fmtp = FMTP.parse_legacy(%{"cm" => "1", "tid" => "2"})
      assert fmtp.cm == 1
      assert fmtp.temporal_id == 2
    end

    test "returns empty struct for invalid parameters" do
      fmtp = FMTP.parse_legacy(%{"profile" => "10"})
      assert %FMTP{} = fmtp
      assert fmtp.profile == nil
    end

    test "handles empty map" do
      fmtp = FMTP.parse_legacy(%{})
      assert %FMTP{} = fmtp
    end
  end

  describe "real-world SDP examples" do
    test "parses WebRTC offer" do
      # Typical WebRTC SDP fmtp line
      assert {:ok, fmtp} = FMTP.parse("profile=0;level-idx=8;tier=0")
      assert fmtp.profile == 0
      assert fmtp.level_idx == 8
      assert fmtp.tier == 0
    end

    test "parses SFU configuration with layer params" do
      # SFU might specify default layer filtering
      assert {:ok, fmtp} = FMTP.parse("profile=0;level-idx=8;cm=1;tid=2;lid=1")
      assert fmtp.profile == 0
      assert fmtp.level_idx == 8
      assert fmtp.cm == 1
      assert fmtp.temporal_id == 2
      assert fmtp.spatial_id == 1
    end

    test "parses minimal configuration" do
      # Just profile constraint
      assert {:ok, fmtp} = FMTP.parse("profile=0")
      assert fmtp.profile == 0
      assert fmtp.level_idx == nil
    end

    test "parses high-quality streaming config" do
      # High profile, Level 5.1, Main tier
      assert {:ok, fmtp} = FMTP.parse("profile=1;level-idx=13;tier=0")
      assert fmtp.profile == 1
      assert fmtp.level_idx == 13
      assert fmtp.tier == 0
    end

    test "parses professional content config" do
      # Professional profile, Level 6.0, High tier
      assert {:ok, fmtp} = FMTP.parse("profile=2;level-idx=16;tier=1")
      assert fmtp.profile == 2
      assert fmtp.level_idx == 16
      assert fmtp.tier == 1
    end
  end

  describe "edge cases" do
    test "handles parameters with no value" do
      # Should fail gracefully
      assert {:error, _} = FMTP.parse("profile")
    end

    test "handles parameters with empty value" do
      # Empty values are treated as nil (not provided)
      assert {:ok, fmtp} = FMTP.parse("profile=")
      assert fmtp.profile == nil
    end

    test "handles malformed parameter string" do
      assert {:error, _} = FMTP.parse("profile=0;invalid")
    end

    test "handles non-numeric values" do
      # Non-numeric strings are treated as nil (invalid)
      assert {:ok, fmtp} = FMTP.parse("profile=abc")
      assert fmtp.profile == nil
    end

    test "handles negative values" do
      # Negative values should fail integer parsing or validation
      params_map = %{profile: -1}
      assert {:error, _} = FMTP.parse_map(params_map)
    end

    test "handles boundary values" do
      # Maximum valid values
      assert {:ok, fmtp} = FMTP.parse("profile=2;level-idx=31;tier=1;cm=1;tid=7;lid=3")
      assert fmtp.profile == 2
      assert fmtp.level_idx == 31
      assert fmtp.tier == 1
      assert fmtp.cm == 1
      assert fmtp.temporal_id == 7
      assert fmtp.spatial_id == 3

      # Minimum valid values
      assert {:ok, fmtp} = FMTP.parse("profile=0;level-idx=0;tier=0;cm=0;tid=0;lid=0")
      assert fmtp.profile == 0
      assert fmtp.level_idx == 0
      assert fmtp.tier == 0
      assert fmtp.cm == 0
      assert fmtp.temporal_id == 0
      assert fmtp.spatial_id == 0
    end
  end

  describe "integration with SDP module" do
    test "can parse fmtp generated by SDP module" do
      # Generate fmtp string using SDP module
      sdp_lines = Membrane.RTP.AV1.SDP.generate(96, profile: 0, level: "4.0", tier: 0)
      fmtp_line = Enum.find(sdp_lines, &String.starts_with?(&1, "a=fmtp:"))

      # Extract just the parameters part (after "a=fmtp:96 ")
      "a=fmtp:96 " <> params = fmtp_line

      # Parse it back
      assert {:ok, fmtp} = FMTP.parse(params)
      assert fmtp.profile == 0
      # Level "4.0" maps to level-idx 8
      assert fmtp.level_idx == 8
      assert fmtp.tier == 0
    end

    test "roundtrip parsing" do
      # Create FMTP, convert to string format, parse back
      original_params = "profile=1;level-idx=13;tier=1;cm=1;tid=2;lid=1"

      assert {:ok, fmtp1} = FMTP.parse(original_params)

      # Reconstruct (in practice, you'd use SDP.fmtp/2)
      reconstructed =
        [
          "profile=#{fmtp1.profile}",
          "level-idx=#{fmtp1.level_idx}",
          "tier=#{fmtp1.tier}",
          "cm=#{fmtp1.cm}",
          "tid=#{fmtp1.temporal_id}",
          "lid=#{fmtp1.spatial_id}"
        ]
        |> Enum.join(";")

      assert {:ok, fmtp2} = FMTP.parse(reconstructed)
      assert fmtp1 == fmtp2
    end
  end
end
