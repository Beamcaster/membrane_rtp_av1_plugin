defmodule Membrane.RTP.AV1.HeaderValidatorTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{HeaderValidator, FullHeader, ScalabilityStructure}

  describe "validate_byte0/1" do
    test "accepts valid header byte with all bits in range" do
      # Z=0, Y=1, W=0, N=0, C=0, M=0, I=0
      b0 = 0b0100_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "rejects header with reserved I bit set" do
      # Same as above but I=1
      b0 = 0b0100_0001
      assert {:error, :reserved_bit_set} = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=1 with Y=0 (single complete OBU)" do
      # Z=0, Y=0, W=1, N=0, C=0, M=0, I=0
      # RFC 9420: W=1 means 1 OBU element, Y=0 means it's complete (no continuation)
      b0 = 0b0001_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=1 with Y=1 (single fragmented OBU)" do
      # Z=0, Y=1, W=1, N=0, C=0, M=0, I=0
      # RFC 9420: W=1 means 1 OBU element, Y=1 means it continues in next packet
      b0 = 0b0101_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=2 with Y=1 (2 OBUs, last continues - hybrid aggregation+fragmentation)" do
      # Z=0, Y=1, W=2, N=0, C=0, M=0, I=0
      # RFC 9420: W=2 means 2 OBU elements, Y=1 means last one continues
      b0 = 0b0110_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=2 with Y=0 (2 complete OBUs)" do
      # Z=0, Y=0, W=2, N=0, C=0, M=0, I=0
      b0 = 0b0010_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=3 with Y=1 (3 OBUs, last continues - hybrid aggregation+fragmentation)" do
      # Z=0, Y=1, W=3, N=0, C=0, M=0, I=0
      # RFC 9420: W=3 means 3 OBU elements, Y=1 means last one continues
      b0 = 0b0111_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=3 with Y=0 (3 complete OBUs)" do
      # Z=0, Y=0, W=3, N=0, C=0, M=0, I=0
      b0 = 0b0011_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end

    test "accepts W=0 (not fragmented) with any Y value" do
      # Y=0
      b0 = 0b0000_0000
      assert :ok = HeaderValidator.validate_byte0(b0)

      # Y=1
      b0 = 0b0100_0000
      assert :ok = HeaderValidator.validate_byte0(b0)
    end
  end

  describe "validate_ids_byte/1" do
    test "accepts valid IDS byte with all fields in range" do
      # T=3, L=1, reserved=000
      b1 = 0b0110_1000
      assert :ok = HeaderValidator.validate_ids_byte(b1)
    end

    test "accepts IDS byte with max valid values" do
      # T=7, L=3, reserved=000
      b1 = 0b1111_1000
      assert :ok = HeaderValidator.validate_ids_byte(b1)
    end

    test "accepts IDS byte with min valid values" do
      # T=0, L=0, reserved=000
      b1 = 0b0000_0000
      assert :ok = HeaderValidator.validate_ids_byte(b1)
    end

    test "rejects IDS byte with reserved bit 0 set" do
      # T=0, L=0, reserved=001
      b1 = 0b0000_0001
      assert {:error, :reserved_ids_bits_set} = HeaderValidator.validate_ids_byte(b1)
    end

    test "rejects IDS byte with reserved bit 1 set" do
      # T=0, L=0, reserved=010
      b1 = 0b0000_0010
      assert {:error, :reserved_ids_bits_set} = HeaderValidator.validate_ids_byte(b1)
    end

    test "rejects IDS byte with reserved bit 2 set" do
      # T=0, L=0, reserved=100
      b1 = 0b0000_0100
      assert {:error, :reserved_ids_bits_set} = HeaderValidator.validate_ids_byte(b1)
    end

    test "rejects IDS byte with all reserved bits set" do
      # T=0, L=0, reserved=111
      b1 = 0b0000_0111
      assert {:error, :reserved_ids_bits_set} = HeaderValidator.validate_ids_byte(b1)
    end
  end

  describe "validate_for_encode/1" do
    test "accepts valid header without fragmentation" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "accepts valid header with first fragment" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 1,
        n: false,
        c: 0,
        m: false
      }

      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "accepts W=1 with Y=0 (single complete OBU)" do
      header = %FullHeader{
        z: false,
        y: false,
        w: 1,
        n: false,
        c: 0,
        m: false
      }

      # RFC 9420: W=1 means 1 OBU element, Y=0 means complete (valid)
      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "accepts W=2 with Y=1 (hybrid aggregation+fragmentation)" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 2,
        n: false,
        c: 0,
        m: false
      }

      # RFC 9420: W=2 means 2 OBU elements, Y=1 means last continues (valid hybrid)
      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "accepts valid header with IDS" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        spatial_id: 1
      }

      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "rejects M=1 without temporal_id/spatial_id" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: nil,
        spatial_id: nil
      }

      assert {:error, :m_set_without_ids} = HeaderValidator.validate_for_encode(header)
    end

    test "rejects invalid temporal_id > 7" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 8,
        spatial_id: 0
      }

      assert {:error, :invalid_temporal_id} = HeaderValidator.validate_for_encode(header)
    end

    test "rejects invalid spatial_id > 3" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 4
      }

      assert {:error, :invalid_spatial_id} = HeaderValidator.validate_for_encode(header)
    end

    test "accepts valid header with SS" do
      ss = ScalabilityStructure.simple(1920, 1080)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      assert :ok = HeaderValidator.validate_for_encode(header)
    end

    test "rejects Z=1 without SS" do
      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: nil
      }

      assert {:error, :z_set_without_ss} = HeaderValidator.validate_for_encode(header)
    end

    test "accepts valid header with all features" do
      ss = ScalabilityStructure.simple(1920, 1080)

      header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: true,
        c: 1,
        m: true,
        temporal_id: 2,
        spatial_id: 1,
        scalability_structure: ss
      }

      assert :ok = HeaderValidator.validate_for_encode(header)
    end
  end

  describe "error_message/1" do
    test "returns readable message for reserved_bit_set" do
      msg = HeaderValidator.error_message({:error, :reserved_bit_set})
      assert msg =~ "Reserved bit"
      assert msg =~ "must be 0"
    end

    test "returns readable message for invalid_w_value" do
      msg = HeaderValidator.error_message({:error, :invalid_w_value})
      assert msg =~ "W"
      assert msg =~ "0-3"
    end

    test "returns readable message for all error types" do
      errors = [
        :reserved_bit_set,
        :invalid_w_value,
        :invalid_c_value,
        :invalid_temporal_id,
        :invalid_spatial_id,
        :reserved_ids_bits_set,
        :z_set_without_ss,
        :m_set_without_ids
      ]

      for error <- errors do
        msg = HeaderValidator.error_message({:error, error})
        assert is_binary(msg)
        assert String.length(msg) > 10
      end
    end
  end

  describe "FullHeader integration" do
    test "decode rejects malformed header with reserved I bit set" do
      # Valid header except I=1
      binary = <<0b0100_0001>>
      assert {:error, :reserved_bit_set} = FullHeader.decode(binary)
    end

    test "decode accepts any valid W/Y combination per RFC 9420" do
      # W=1, Y=0 (valid: single complete OBU element)
      binary = <<0b0001_0000>>
      assert {:ok, %FullHeader{w: 1, y: false}, ""} = FullHeader.decode(binary)

      # W=3, Y=1 (valid: 3 OBU elements, last continues - hybrid)
      binary2 = <<0b0111_0000>>
      assert {:ok, %FullHeader{w: 3, y: true}, ""} = FullHeader.decode(binary2)
    end

    test "decode rejects IDS byte with reserved bits set" do
      # Header with M=1, then IDS byte with reserved bits
      # M=1
      header_byte = 0b0000_0010
      # reserved=111
      ids_byte = 0b0000_0111
      binary = <<header_byte, ids_byte>>

      # IDSValidator returns :reserved_kid_bits_set, not :reserved_ids_bits_set
      assert {:error, :reserved_kid_bits_set} = FullHeader.decode(binary)
    end

    test "decode accepts valid header" do
      # Z=0, Y=1, W=0, N=0, C=0, M=0, I=0
      binary = <<0b0100_0000>>
      assert {:ok, header, <<>>} = FullHeader.decode(binary)
      assert header.y == true
      assert header.w == 0
    end

    test "decode accepts valid header with IDS" do
      # Header: M=1, Y=1
      header_byte = 0b0100_0010
      # IDS: T=3, L=1, reserved=000
      ids_byte = 0b0110_1000
      binary = <<header_byte, ids_byte>>

      assert {:ok, header, <<>>} = FullHeader.decode(binary)
      assert header.m == true
      assert header.temporal_id == 3
      assert header.spatial_id == 1
    end

    test "round-trip with validation" do
      header = %FullHeader{
        z: false,
        y: true,
        w: 1,
        n: false,
        c: 0,
        m: true,
        temporal_id: 5,
        spatial_id: 2
      }

      encoded = FullHeader.encode(header)
      assert {:ok, decoded, <<>>} = FullHeader.decode(encoded)

      assert decoded.y == header.y
      assert decoded.w == header.w
      assert decoded.m == header.m
      assert decoded.temporal_id == header.temporal_id
      assert decoded.spatial_id == header.spatial_id
    end
  end
end
