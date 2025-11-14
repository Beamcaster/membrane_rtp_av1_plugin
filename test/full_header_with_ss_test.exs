defmodule Membrane.RTP.AV1.FullHeaderWithSSTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{FullHeader, ScalabilityStructure}

  describe "FullHeader with SS integration" do
    test "encodes and decodes header without SS (Z=0)" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: nil
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.z == false
      assert decoded.scalability_structure == nil
    end

    test "encodes and decodes header with SS (Z=1)" do
      ss = ScalabilityStructure.simple(1920, 1080, frame_rate: 30, temporal_layers: 2)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert is_binary(encoded)
      assert byte_size(encoded) > 1

      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)
      assert decoded.z == true
      assert decoded.scalability_structure != nil
      assert decoded.scalability_structure.n_s == ss.n_s
      assert decoded.scalability_structure.spatial_layers == ss.spatial_layers
    end

    test "encodes and decodes header with SS and IDS (Z=1, M=1)" do
      # Create SS with 4 temporal layers (0-3) so temporal_id=3 is valid
      ss = ScalabilityStructure.simple(1280, 720, temporal_layers: 4)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        # simple() creates n_s=0, so max spatial_id=0
        spatial_id: 0,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.z == true
      assert decoded.m == true
      assert decoded.temporal_id == 3
      assert decoded.spatial_id == 0
      assert decoded.scalability_structure != nil
    end

    test "handles SVC SS structure" do
      ss = ScalabilityStructure.svc([{640, 360}, {1280, 720}, {1920, 1080}], 3)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.scalability_structure.n_s == 2
      assert decoded.scalability_structure.n_g == 9
      assert length(decoded.scalability_structure.spatial_layers) == 3
    end

    test "handles fragmentation with SS" do
      ss = ScalabilityStructure.simple(1920, 1080)

      header = %FullHeader{
        z: true,
        y: true,
        w: 1,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.w == 1
      assert decoded.scalability_structure != nil
    end

    test "gracefully handles SS encoding failure" do
      # Create an invalid SS that will fail encoding
      invalid_ss = %ScalabilityStructure{
        n_s: 8,
        y_flag: false,
        n_g: 1,
        spatial_layers: [],
        pictures: []
      }

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: invalid_ss
      }

      # Should encode without SS if encoding fails
      encoded = FullHeader.encode(header)
      assert is_binary(encoded)
      # Should only be 1 byte (base header, no SS appended)
      assert byte_size(encoded) == 1
    end

    test "preserves trailing payload data after SS" do
      ss = ScalabilityStructure.simple(640, 480)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      payload = <<1, 2, 3, 4, 5>>
      encoded = FullHeader.encode(header) <> payload

      assert {:ok, decoded, rest} = FullHeader.decode(encoded)
      assert decoded.scalability_structure != nil
      assert rest == payload
    end

    test "rejects invalid SS on decode" do
      # Manually craft a header with Z=1 but invalid SS data
      # Z=1, rest=0
      header_byte = 0b1000_0000
      # Invalid SS data
      invalid_ss = <<0xFF, 0xFF, 0xFF>>

      binary = <<header_byte>> <> invalid_ss

      # Should return error when SS decode fails
      result = FullHeader.decode(binary)
      assert match?({:error, _}, result)
    end

    test "handles missing IDS byte when M=1" do
      # M=1, but no IDS byte follows
      header_byte = 0b0000_0010

      assert {:error, :missing_ids_byte} = FullHeader.decode(<<header_byte>>)
    end

    test "round-trip with all features enabled" do
      # Create SVC with 3 temporal layers (0-2) so temporal_id=2 is valid
      ss = ScalabilityStructure.svc([{1920, 1080}], 3)

      header = %FullHeader{
        z: true,
        y: true,
        w: 1,
        n: true,
        c: 1,
        m: true,
        temporal_id: 2,
        spatial_id: 0,
        scalability_structure: ss
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.z == true
      assert decoded.y == true
      assert decoded.w == 1
      assert decoded.n == true
      assert decoded.c == 1
      assert decoded.m == true
      assert decoded.temporal_id == 2
      assert decoded.spatial_id == 0
      assert decoded.scalability_structure != nil
      assert decoded.scalability_structure.n_s == ss.n_s
    end
  end
end
