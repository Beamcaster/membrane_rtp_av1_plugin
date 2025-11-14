defmodule Membrane.RTP.AV1.TUDetectorTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{TUDetector, OBU}

  describe "detect_tu_boundaries/1" do
    test "single frame access unit" do
      # Create a simple access unit with one frame
      frame_obu = create_frame_obu(<<0x01, 0x02, 0x03>>)
      au = frame_obu

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 1
      assert length(tu.obus) == 1
    end

    test "access unit with temporal delimiter" do
      # Temporal delimiter + frame
      td_obu = create_temporal_delimiter_obu()
      frame_obu = create_frame_obu(<<0x01, 0x02>>)
      au = td_obu <> frame_obu

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 1
      assert length(tu.obus) == 2
    end

    test "access unit with sequence header and frame" do
      seq_hdr_obu = create_sequence_header_obu()
      frame_obu = create_frame_obu(<<0x01, 0x02>>)
      au = seq_hdr_obu <> frame_obu

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 1
    end

    test "access unit with frame header and tile group" do
      frame_hdr_obu = create_frame_header_obu(<<0x01>>)
      tile_group_obu = create_tile_group_obu(<<0x02, 0x03>>)
      au = frame_hdr_obu <> tile_group_obu

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 1
      assert length(tu.obus) == 2
    end

    test "access unit with metadata and padding" do
      frame_obu = create_frame_obu(<<0x01>>)
      metadata_obu = create_metadata_obu(<<0x00, 0x01>>)
      padding_obu = create_padding_obu(<<0x00, 0x00>>)
      au = frame_obu <> metadata_obu <> padding_obu

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 1
      assert length(tu.obus) == 3
    end

    test "multiple frames in single access unit" do
      # Two separate frames
      frame1 = create_frame_obu(<<0x01>>)
      frame2 = create_frame_obu(<<0x02>>)
      au = frame1 <> frame2

      tus = TUDetector.detect_tu_boundaries(au)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 2
    end

    test "empty access unit" do
      tus = TUDetector.detect_tu_boundaries(<<>>)

      assert length(tus) == 1
      [tu] = tus
      assert tu.is_tu_end == true
      assert tu.frame_count == 0
      assert tu.obus == []
    end

    test "malformed OBU handled gracefully" do
      # Invalid LEB128
      malformed = <<0xFF, 0xFF, 0xFF>>

      tus = TUDetector.detect_tu_boundaries(malformed)

      # Should still return a TU
      assert length(tus) >= 1
    end
  end

  describe "assign_markers/2" do
    test "single packet gets marker" do
      packets = [<<1, 2, 3>>]
      tus = [%{obus: [], is_tu_end: true, frame_count: 1}]

      result = TUDetector.assign_markers(packets, tus)

      assert result == [{<<1, 2, 3>>, true}]
    end

    test "multiple packets, single TU" do
      packets = [<<1>>, <<2>>, <<3>>]
      tus = [%{obus: [], is_tu_end: true, frame_count: 1}]

      result = TUDetector.assign_markers(packets, tus)

      assert result == [{<<1>>, false}, {<<2>>, false}, {<<3>>, true}]
    end

    test "multiple packets, multiple TUs" do
      packets = [<<1>>, <<2>>, <<3>>]

      tus = [
        %{obus: [], is_tu_end: true, frame_count: 1},
        %{obus: [], is_tu_end: true, frame_count: 1}
      ]

      result = TUDetector.assign_markers(packets, tus)

      # For now, implementation marks only last packet
      # TODO: Implement proper packet-to-TU mapping
      assert [{<<1>>, false}, {<<2>>, false}, {<<3>>, true}] = result
    end

    test "empty packet list" do
      tus = [%{obus: [], is_tu_end: true, frame_count: 1}]

      result = TUDetector.assign_markers([], tus)

      assert result == []
    end
  end

  # Helper functions to create test OBUs

  defp create_frame_obu(payload) do
    # OBU type 6 (FRAME), no extension, has size field
    # Byte 0: F=0, type=6 (0110), X=0, has_size=1, reserved=00
    # Binary: 0_0110_0_1_00 = 0x32
    obu_header = <<0x32>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_temporal_delimiter_obu do
    # OBU type 2 (TEMPORAL_DELIMITER)
    # Byte 0: F=0, type=2 (0010), X=0, has_size=1, reserved=00
    # Binary: 0_0010_0_1_00 = 0x12
    obu_header = <<0x12>>
    OBU.build_obu(obu_header <> <<>>)
  end

  defp create_sequence_header_obu do
    # OBU type 1 (SEQUENCE_HEADER)
    # Byte 0: F=0, type=1 (0001), X=0, has_size=1, reserved=00
    # Binary: 0_0001_0_1_00 = 0x0A
    obu_header = <<0x0A>>
    # Minimal sequence header payload
    payload = <<0x00, 0x00, 0x00>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_frame_header_obu(payload) do
    # OBU type 3 (FRAME_HEADER)
    # Byte 0: F=0, type=3 (0011), X=0, has_size=1, reserved=00
    # Binary: 0_0011_0_1_00 = 0x1A
    obu_header = <<0x1A>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_tile_group_obu(payload) do
    # OBU type 4 (TILE_GROUP)
    # Byte 0: F=0, type=4 (0100), X=0, has_size=1, reserved=00
    # Binary: 0_0100_0_1_00 = 0x22
    obu_header = <<0x22>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_metadata_obu(payload) do
    # OBU type 5 (METADATA)
    # Byte 0: F=0, type=5 (0101), X=0, has_size=1, reserved=00
    # Binary: 0_0101_0_1_00 = 0x2A
    obu_header = <<0x2A>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_padding_obu(payload) do
    # OBU type 15 (PADDING)
    # Byte 0: F=0, type=15 (1111), X=0, has_size=1, reserved=00
    # Binary: 0_1111_0_1_00 = 0x7A
    obu_header = <<0x7A>>
    OBU.build_obu(obu_header <> payload)
  end
end
