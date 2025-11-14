defmodule Membrane.RTP.AV1.OBUHeaderTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Membrane.RTP.AV1.OBUHeader

  describe "parse/1 - basic OBU header" do
    test "parses SEQUENCE_HEADER (type=1) without extension" do
      # Bits: F(0) | type(0001) | X(0) | S(1) | reserved(0)
      # Binary: 00001010 = 0x0A
      b0 = 0x0A
      payload = <<1, 2, 3, 4>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :sequence_header
      assert header.obu_type_value == 1
      assert header.obu_forbidden_bit == 0
      assert header.obu_extension_flag == false
      assert header.obu_has_size_field == true
      assert header.temporal_id == nil
      assert header.spatial_id == nil
      assert header.discardable? == false
    end

    test "parses FRAME (type=6) without extension" do
      # Bits: F(0) | type(0110) | X(0) | S(1) | reserved(0)
      # Binary: 00110010 = 0x32
      b0 = 0x32
      payload = <<10, 20, 30>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :frame
      assert header.obu_type_value == 6
      assert header.discardable? == false
    end

    test "parses METADATA (type=5) without extension" do
      # Bits: F(0) | type(0101) | X(0) | S(1) | reserved(0)
      # Binary: 00101010 = 0x2A
      b0 = 0x2A
      payload = <<100>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :metadata
      assert header.obu_type_value == 5
      assert header.discardable? == true
    end

    test "parses PADDING (type=15) without extension" do
      # Bits: F(0) | type(1111) | X(0) | S(1) | reserved(0)
      # Binary: 01111010 = 0x7A
      b0 = 0x7A
      payload = <<0, 0, 0>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :padding
      assert header.obu_type_value == 15
      assert header.discardable? == true
    end

    test "parses TILE_LIST (type=8)" do
      # Bits: F(0) | type(1000) | X(0) | S(1) | reserved(0)
      # Binary: 01000010 = 0x42
      b0 = 0x42
      payload = <<1, 2>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :tile_list
      assert header.discardable? == true
    end

    test "parses TEMPORAL_DELIMITER (type=2)" do
      # Bits: F(0) | type(0010) | X(0) | S(1) | reserved(0)
      # Binary: 00010010 = 0x12
      b0 = 0x12
      payload = <<>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0>> <> payload)
      assert header.obu_type == :temporal_delimiter
      assert header.discardable? == false
    end

    test "rejects header with forbidden bit set" do
      # Bits: F(1) | type(0110) | X(0) | S(1) | reserved(0)
      # Binary: 10110010 = 0xB2
      b0 = 0xB2
      payload = <<1, 2>>

      assert {:error, :obu_forbidden_bit_set} = OBUHeader.parse(<<b0>> <> payload)
    end

    test "returns error for empty binary" do
      assert {:error, :invalid_obu_header} = OBUHeader.parse(<<>>)
    end
  end

  describe "parse/1 - with extension header" do
    test "parses OBU with extension (TID=3, LID=1)" do
      # Bits: F(0) | type(0110) | X(1) | S(1) | reserved(0)
      # Binary: 00110110 = 0x36
      b0 = 0x36
      # Extension: TID(011) | LID(01) | reserved(000)
      # Binary: 01101000 = 0x68
      b1 = 0x68
      payload = <<100, 200>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0, b1>> <> payload)
      assert header.obu_extension_flag == true
      assert header.temporal_id == 3
      assert header.spatial_id == 1
    end

    test "parses OBU with extension (TID=7, LID=3)" do
      # Bits: F(0) | type(0001) | X(1) | S(1) | reserved(0)
      # Binary: 00001110 = 0x0E
      b0 = 0x0E
      # Extension: TID(111) | LID(11) | reserved(000)
      # Binary: 11111000 = 0xF8
      b1 = 0xF8
      payload = <<50>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0, b1>> <> payload)
      assert header.temporal_id == 7
      assert header.spatial_id == 3
    end

    test "parses OBU with extension (TID=0, LID=0)" do
      # Bits: F(0) | type(0110) | X(1) | S(1) | reserved(0)
      # Binary: 00110110 = 0x36
      b0 = 0x36
      # Extension: TID(000) | LID(00) | reserved(000)
      # Binary: 00000000 = 0x00
      b1 = 0x00
      payload = <<>>

      assert {:ok, header, ^payload} = OBUHeader.parse(<<b0, b1>> <> payload)
      assert header.temporal_id == 0
      assert header.spatial_id == 0
    end

    test "rejects extension with reserved bits set" do
      # Bits: F(0) | type(0110) | X(1) | S(1) | reserved(0)
      # Binary: 00110110 = 0x36
      b0 = 0x36
      # Extension: TID(011) | LID(01) | reserved(111) - INVALID!
      # Binary: 01101111 = 0x6F
      b1 = 0x6F
      payload = <<1, 2>>

      assert {:error, :obu_extension_reserved_bits_set} =
               OBUHeader.parse(<<b0, b1>> <> payload)
    end

    test "returns error when extension flag set but byte missing" do
      # Bits: F(0) | type(0110) | X(1) | S(1) | reserved(0)
      # Binary: 00110110 = 0x36
      b0 = 0x36
      # No extension byte follows

      assert {:error, :missing_obu_extension_byte} = OBUHeader.parse(<<b0>>)
    end
  end

  describe "parse_obus/1" do
    test "parses multiple OBUs with LEB128 prefix" do
      # OBU 1: FRAME (type=6), no extension, 5 bytes total (1 header + 4 payload)
      # Header: 0x32 (type=6, X=0, S=1)
      obu1 = <<5, 0x32, 1, 2, 3, 4, 5>>

      # OBU 2: METADATA (type=5), no extension, 3 bytes total
      # Header: 0x2A (type=5, X=0, S=1)
      obu2 = <<3, 0x2A, 10, 20, 30>>

      # OBU 3: PADDING (type=15), no extension, 2 bytes total
      # Header: 0x7A (type=15, X=0, S=1)
      obu3 = <<2, 0x7A, 0, 0>>

      assert {:ok, headers} = OBUHeader.parse_obus([obu1, obu2, obu3])
      assert length(headers) == 3

      assert Enum.at(headers, 0).obu_type == :frame
      assert Enum.at(headers, 1).obu_type == :metadata
      assert Enum.at(headers, 2).obu_type == :padding
    end

    test "parses OBUs with extensions" do
      # OBU with extension: type=6, TID=2, LID=1
      # Header: 0x36 (type=6, X=1, S=1)
      # Extension: 0x50 (TID=010, LID=10, reserved=000)
      obu = <<3, 0x36, 0x50, 10, 20>>

      assert {:ok, [header]} = OBUHeader.parse_obus([obu])
      assert header.temporal_id == 2
      assert header.spatial_id == 2
    end

    test "returns error for malformed OBU" do
      # OBU with forbidden bit set: 0xB2 (F=1, type=6, X=0, S=1)
      obu = <<2, 0xB2, 1, 2>>

      assert {:error, :obu_forbidden_bit_set} = OBUHeader.parse_obus([obu])
    end

    test "handles empty list" do
      assert {:ok, []} = OBUHeader.parse_obus([])
    end
  end

  describe "determine_cm/1" do
    test "returns 0 for all discardable OBUs" do
      headers = [
        %OBUHeader{obu_type: :metadata, discardable?: true},
        %OBUHeader{obu_type: :padding, discardable?: true},
        %OBUHeader{obu_type: :tile_list, discardable?: true}
      ]

      assert OBUHeader.determine_cm(headers) == 0
    end

    test "returns 1 for all non-discardable OBUs" do
      headers = [
        %OBUHeader{obu_type: :sequence_header, discardable?: false},
        %OBUHeader{obu_type: :frame, discardable?: false}
      ]

      assert OBUHeader.determine_cm(headers) == 1
    end

    test "returns 1 for mixed discardability" do
      headers = [
        %OBUHeader{obu_type: :frame, discardable?: false},
        %OBUHeader{obu_type: :metadata, discardable?: true},
        %OBUHeader{obu_type: :padding, discardable?: true}
      ]

      assert OBUHeader.determine_cm(headers) == 1
    end

    test "returns 1 for single non-discardable OBU" do
      headers = [
        %OBUHeader{obu_type: :frame_header, discardable?: false}
      ]

      assert OBUHeader.determine_cm(headers) == 1
    end

    test "returns 0 for single discardable OBU" do
      headers = [
        %OBUHeader{obu_type: :metadata, discardable?: true}
      ]

      assert OBUHeader.determine_cm(headers) == 0
    end

    test "returns 0 for empty list" do
      assert OBUHeader.determine_cm([]) == 0
    end
  end

  describe "determine_cm_from_obus/1" do
    test "determines CM=1 for frame OBUs" do
      # FRAME OBU: type=6
      obu = <<3, 0x32, 1, 2, 3>>

      assert {:ok, 1} = OBUHeader.determine_cm_from_obus([obu])
    end

    test "determines CM=0 for metadata only" do
      # METADATA OBU: type=5
      obu = <<2, 0x2A, 10, 20>>

      assert {:ok, 0} = OBUHeader.determine_cm_from_obus([obu])
    end

    test "determines CM=1 for mixed OBUs" do
      frame_obu = <<3, 0x32, 1, 2, 3>>
      metadata_obu = <<2, 0x2A, 10, 20>>

      assert {:ok, 1} = OBUHeader.determine_cm_from_obus([frame_obu, metadata_obu])
    end

    test "determines CM=0 for all padding" do
      pad1 = <<1, 0x7A, 0>>
      pad2 = <<1, 0x7A, 0>>

      assert {:ok, 0} = OBUHeader.determine_cm_from_obus([pad1, pad2])
    end

    test "returns error for malformed OBU" do
      # Forbidden bit set: 0xB2
      obu = <<2, 0xB2, 1, 2>>

      assert {:error, :obu_forbidden_bit_set} = OBUHeader.determine_cm_from_obus([obu])
    end
  end

  describe "discardable?/1" do
    test "non-discardable OBU types" do
      refute OBUHeader.discardable?(:sequence_header)
      refute OBUHeader.discardable?(:temporal_delimiter)
      refute OBUHeader.discardable?(:frame_header)
      refute OBUHeader.discardable?(:tile_group)
      refute OBUHeader.discardable?(:frame)
    end

    test "discardable OBU types" do
      assert OBUHeader.discardable?(:metadata)
      assert OBUHeader.discardable?(:redundant_frame_header)
      assert OBUHeader.discardable?(:tile_list)
      assert OBUHeader.discardable?(:padding)
      assert OBUHeader.discardable?(:reserved)
    end
  end

  describe "obu_type_name/1" do
    test "returns readable names for all OBU types" do
      assert OBUHeader.obu_type_name(:sequence_header) == "OBU_SEQUENCE_HEADER"
      assert OBUHeader.obu_type_name(:temporal_delimiter) == "OBU_TEMPORAL_DELIMITER"
      assert OBUHeader.obu_type_name(:frame_header) == "OBU_FRAME_HEADER"
      assert OBUHeader.obu_type_name(:tile_group) == "OBU_TILE_GROUP"
      assert OBUHeader.obu_type_name(:metadata) == "OBU_METADATA"
      assert OBUHeader.obu_type_name(:frame) == "OBU_FRAME"
      assert OBUHeader.obu_type_name(:redundant_frame_header) == "OBU_REDUNDANT_FRAME_HEADER"
      assert OBUHeader.obu_type_name(:tile_list) == "OBU_TILE_LIST"
      assert OBUHeader.obu_type_name(:padding) == "OBU_PADDING"
      assert OBUHeader.obu_type_name(:reserved) == "OBU_RESERVED"
    end
  end

  describe "integration with LEB128" do
    test "handles multi-byte LEB128 prefix" do
      # LEB128 for value 200: 0xC8 0x01
      leb = <<0x88 ||| 0x80, 0x01>>
      # FRAME header: type=6
      obu_header = <<0x32>>
      payload = :binary.copy(<<0>>, 200)

      obu = leb <> obu_header <> payload

      assert {:ok, [header]} = OBUHeader.parse_obus([obu])
      assert header.obu_type == :frame
    end

    test "handles single-byte LEB128" do
      # LEB128 for value 10
      leb = <<10>>
      # METADATA header: type=5
      obu_header = <<0x2A>>
      payload = :binary.copy(<<1>>, 10)

      obu = leb <> obu_header <> payload

      assert {:ok, [header]} = OBUHeader.parse_obus([obu])
      assert header.obu_type == :metadata
    end
  end
end
