defmodule Membrane.RTP.AV1.IDSIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{FullHeader, ScalabilityStructure, IDSValidator}

  describe "FullHeader encode/decode with IDS" do
    test "encodes and decodes header with M=1, TID=3, LID=1" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        spatial_id: 1
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.m == true
      assert decoded.temporal_id == 3
      assert decoded.spatial_id == 1
    end

    test "encodes and decodes header with M=1, all TID/LID combinations" do
      for tid <- 0..7, lid <- 0..3 do
        header = %FullHeader{
          z: false,
          y: false,
          w: 0,
          n: false,
          c: 0,
          m: true,
          temporal_id: tid,
          spatial_id: lid
        }

        encoded = FullHeader.encode(header)
        assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

        assert decoded.temporal_id == tid
        assert decoded.spatial_id == lid
      end
    end

    test "decodes reject malformed IDS byte with reserved bits set" do
      # Valid header byte 0: M=1
      b0 = 0b00000010
      # Invalid IDS byte: TID=3, LID=1, reserved=111
      b1 = 0b01101111

      assert {:error, :reserved_kid_bits_set} = FullHeader.decode(<<b0, b1>>)
    end

    test "encodes header without IDS when M=0" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: false,
        temporal_id: nil,
        spatial_id: nil
      }

      encoded = FullHeader.encode(header)
      # Should be only 1 byte (no IDS byte)
      assert byte_size(encoded) == 1
    end

    test "returns error when M=1 but IDS byte is missing" do
      # Header with M=1 but no IDS byte following
      b0 = 0b00000010

      assert {:error, :missing_ids_byte} = FullHeader.decode(<<b0>>)
    end
  end

  describe "FullHeader with IDS + SS capability validation" do
    test "accepts IDS within SS capabilities (simple stream)" do
      # Simple stream with 3 temporal layers
      ss = ScalabilityStructure.simple(1920, 1080, temporal_layers: 3)

      header = %FullHeader{
        z: true,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 2,
        spatial_id: 0,
        scalability_structure: ss
      }

      # Encode with SS
      encoded = FullHeader.encode(header)

      # Decode and validate
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.temporal_id == 2
      assert decoded.spatial_id == 0
      assert decoded.scalability_structure != nil
    end

    test "rejects IDS exceeding SS temporal capability" do
      ss = %ScalabilityStructure{
        n_s: 0,
        y_flag: false,
        n_g: 2,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: 30}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0]},
          %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [1]}
        ]
      }

      # Encode valid SS
      {:ok, ss_bin} = ScalabilityStructure.encode(ss)

      # Build header with TID=5 (exceeds SS max TID=1)
      # Z=1, M=1
      b0 = 0b10000010
      # TID=5, LID=0
      b1 = IDSValidator.encode_ids_byte(5, 0)

      packet = <<b0, b1>> <> ss_bin

      # Should reject during decode
      assert {:error, :temporal_id_exceeds_capability} = FullHeader.decode(packet)
    end

    test "rejects IDS exceeding SS spatial capability" do
      ss = %ScalabilityStructure{
        n_s: 0,
        y_flag: false,
        n_g: 1,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: 30}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0]}
        ]
      }

      {:ok, ss_bin} = ScalabilityStructure.encode(ss)

      # Build header with LID=2 (exceeds SS n_s=0, max LID=0)
      # Z=1, M=1
      b0 = 0b10000010
      # TID=0, LID=2
      b1 = IDSValidator.encode_ids_byte(0, 2)

      packet = <<b0, b1>> <> ss_bin

      assert {:error, :spatial_id_exceeds_capability} = FullHeader.decode(packet)
    end

    test "accepts IDS within SVC SS capabilities" do
      # SVC: 2 spatial layers, 2 temporal layers each
      ss = ScalabilityStructure.svc([{1920, 1080}, {960, 540}], 2)

      # Test valid combinations
      for tid <- 0..1, lid <- 0..1 do
        header = %FullHeader{
          z: true,
          y: false,
          w: 0,
          n: false,
          c: 0,
          m: true,
          temporal_id: tid,
          spatial_id: lid,
          scalability_structure: ss
        }

        encoded = FullHeader.encode(header)
        assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
        assert decoded.temporal_id == tid
        assert decoded.spatial_id == lid
      end
    end
  end

  describe "IDS validation across multiple packets" do
    test "first packet with Z=1 (SS), subsequent with Z=0 (IDS only)" do
      # First packet: Z=1, M=1 with SS
      ss = ScalabilityStructure.svc([{1920, 1080}, {960, 540}], 1)

      first_packet = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 0,
        scalability_structure: ss
      }

      encoded_first = FullHeader.encode(first_packet)
      assert {:ok, decoded_first, <<>>} = FullHeader.decode(encoded_first)
      assert decoded_first.scalability_structure != nil

      # Subsequent packets: Z=0, M=1 with IDS only
      for lid <- 0..1 do
        subsequent_packet = %FullHeader{
          z: false,
          y: false,
          w: 0,
          n: false,
          c: 0,
          m: true,
          temporal_id: 0,
          spatial_id: lid,
          scalability_structure: nil
        }

        encoded_subsequent = FullHeader.encode(subsequent_packet)
        assert {:ok, decoded_subsequent, <<>>} = FullHeader.decode(encoded_subsequent)
        assert decoded_subsequent.temporal_id == 0
        assert decoded_subsequent.spatial_id == lid
        assert decoded_subsequent.scalability_structure == nil
      end
    end

    test "validates IDS against cached SS capabilities" do
      # In real usage, depayloader would cache SS from Z=1 packet
      # and validate subsequent IDS against it
      ss = ScalabilityStructure.simple(1920, 1080, temporal_layers: 2)

      # Valid IDS within capability
      assert :ok = IDSValidator.validate_ids_with_capabilities(0, 0, ss)
      assert :ok = IDSValidator.validate_ids_with_capabilities(1, 0, ss)

      # Invalid IDS exceeding capability
      assert {:error, :temporal_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(2, 0, ss)

      assert {:error, :spatial_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(0, 1, ss)
    end
  end

  describe "edge cases" do
    test "IDS with maximum valid values" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 7,
        spatial_id: 3
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.temporal_id == 7
      assert decoded.spatial_id == 3
    end

    test "IDS with minimum valid values" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 0
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.temporal_id == 0
      assert decoded.spatial_id == 0
    end

    test "header with Z=1, M=1 (both SS and IDS)" do
      ss = ScalabilityStructure.simple(1920, 1080)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 0,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.m == true
      assert decoded.z == true
      assert decoded.temporal_id == 0
      assert decoded.spatial_id == 0
      assert decoded.scalability_structure != nil
    end

    test "header with Z=0, M=0 (no SS, no IDS)" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      encoded = FullHeader.encode(header)
      assert byte_size(encoded) == 1
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.m == false
      assert decoded.z == false
      assert decoded.temporal_id == nil
      assert decoded.spatial_id == nil
    end
  end
end
