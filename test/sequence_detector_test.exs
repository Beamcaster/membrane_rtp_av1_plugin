defmodule Membrane.RTP.AV1.SequenceDetectorTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.SequenceDetector

  describe "contains_sequence_header?/1" do
    test "detects sequence header in access unit" do
      # Create an access unit with sequence header OBU (type=1)
      # OBU header: F(0) | type(0001) | X(0) | S(1) | reserved(0) = 0x0A
      # OBU size: 4 bytes (LEB128 encoded as 0x04)
      # Payload: <<1, 2, 3, 4>>
      sequence_header_obu = <<0x0A, 0x04, 1, 2, 3, 4>>

      assert SequenceDetector.contains_sequence_header?(sequence_header_obu)
    end

    test "detects sequence header in access unit with multiple OBUs" do
      # Temporal delimiter (type=2): 0x12 + size 0x00
      temporal_delimiter = <<0x12, 0x00>>
      # Sequence header (type=1): 0x0A + size 0x03 + payload
      sequence_header = <<0x0A, 0x03, 10, 20, 30>>
      # Frame (type=6): 0x32 + size 0x02 + payload
      frame = <<0x32, 0x02, 5, 6>>

      access_unit = temporal_delimiter <> sequence_header <> frame

      assert SequenceDetector.contains_sequence_header?(access_unit)
    end

    test "returns false for delta frame without sequence header" do
      # Frame OBU (type=6): F(0) | type(0110) | X(0) | S(1) | reserved(0) = 0x32
      # OBU size: 8 bytes
      frame_obu = <<0x32, 0x08, 1, 2, 3, 4, 5, 6, 7, 8>>

      refute SequenceDetector.contains_sequence_header?(frame_obu)
    end

    test "returns false for empty binary" do
      refute SequenceDetector.contains_sequence_header?(<<>>)
    end

    test "returns false for malformed data" do
      # Invalid OBU with forbidden bit set
      invalid_obu = <<0xFF, 0x00>>

      refute SequenceDetector.contains_sequence_header?(invalid_obu)
    end

    test "returns false for temporal delimiter only" do
      # Temporal delimiter (type=2): 0x12 + size 0x00
      temporal_delimiter = <<0x12, 0x00>>

      refute SequenceDetector.contains_sequence_header?(temporal_delimiter)
    end

    test "handles access unit with metadata and padding" do
      # Metadata (type=5): 0x2A
      metadata = <<0x2A, 0x02, 1, 2>>
      # Padding (type=15): 0x7A
      padding = <<0x7A, 0x03, 0, 0, 0>>

      access_unit = metadata <> padding

      refute SequenceDetector.contains_sequence_header?(access_unit)
    end
  end

  describe "extract_sequence_header/1" do
    test "extracts sequence header OBU from access unit" do
      # Sequence header OBU
      sequence_header_obu = <<0x0A, 0x05, 1, 2, 3, 4, 5>>

      result = SequenceDetector.extract_sequence_header(sequence_header_obu)

      assert result == sequence_header_obu
    end

    test "extracts sequence header from access unit with multiple OBUs" do
      # Temporal delimiter
      temporal_delimiter = <<0x12, 0x00>>
      # Sequence header
      sequence_header = <<0x0A, 0x04, 10, 20, 30, 40>>
      # Frame
      frame = <<0x32, 0x03, 100, 101, 102>>

      access_unit = temporal_delimiter <> sequence_header <> frame

      result = SequenceDetector.extract_sequence_header(access_unit)

      assert result == sequence_header
    end

    test "returns nil when no sequence header present" do
      # Frame only
      frame_obu = <<0x32, 0x04, 1, 2, 3, 4>>

      assert SequenceDetector.extract_sequence_header(frame_obu) == nil
    end

    test "returns nil for empty binary" do
      assert SequenceDetector.extract_sequence_header(<<>>) == nil
    end

    test "returns nil for malformed data" do
      # Invalid OBU
      invalid_obu = <<0xFF, 0x00>>

      assert SequenceDetector.extract_sequence_header(invalid_obu) == nil
    end

    test "extracts correct sequence header when multiple OBUs follow" do
      # Sequence header
      seq_header = <<0x0A, 0x02, 55, 66>>
      # Frame header (type=3): 0x1A
      frame_header = <<0x1A, 0x01, 77>>
      # Tile group (type=4): 0x22
      tile_group = <<0x22, 0x02, 88, 99>>

      access_unit = seq_header <> frame_header <> tile_group

      result = SequenceDetector.extract_sequence_header(access_unit)

      assert result == seq_header
    end
  end

  describe "sequence header detection with realistic data" do
    test "detects sequence header in keyframe" do
      # Typical keyframe structure:
      # TD (0x12, 0x00)
      # Sequence Header (0x0A, size, payload)
      # Frame (0x32, size, payload)

      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x06>> <> <<1, 2, 3, 4, 5, 6>>
      frame = <<0x32, 0x0A>> <> :binary.copy(<<0xFF>>, 10)

      keyframe = temporal_delimiter <> sequence_header <> frame

      assert SequenceDetector.contains_sequence_header?(keyframe)

      extracted = SequenceDetector.extract_sequence_header(keyframe)
      assert extracted == sequence_header
    end

    test "does not detect sequence header in delta frame" do
      # Typical delta frame structure:
      # TD (0x12, 0x00)
      # Frame (0x32, size, payload)

      temporal_delimiter = <<0x12, 0x00>>
      frame = <<0x32, 0x08>> <> :binary.copy(<<0xAA>>, 8)

      delta_frame = temporal_delimiter <> frame

      refute SequenceDetector.contains_sequence_header?(delta_frame)
      assert SequenceDetector.extract_sequence_header(delta_frame) == nil
    end
  end
end
