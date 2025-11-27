defmodule Membrane.RTP.AV1.NBitIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{PayloadFormat, FullHeader}

  @moduledoc """
  Integration tests for N bit (new coded video sequence) generation.

  Per AV1 RTP spec section 4.4, the N bit MUST be set to 1 for the first packet
  of a coded video sequence (typically keyframes with sequence headers).
  """

  describe "N bit generation in spec mode" do
    test "first packet of keyframe with sequence header has N=1" do
      # Create a keyframe: Temporal Delimiter + Sequence Header + Frame
      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x06>> <> <<1, 2, 3, 4, 5, 6>>
      frame = <<0x32, 0x0A>> <> :binary.copy(<<0xFF>>, 10)

      keyframe = temporal_delimiter <> sequence_header <> frame

      packets =
        PayloadFormat.fragment(keyframe,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{}
        )

      assert is_list(packets)
      assert length(packets) >= 1

      # First packet should have N=1
      first_packet = hd(packets)
      assert {:ok, header, _payload} = FullHeader.decode(first_packet)
      assert header.n == true, "First packet of keyframe must have N=1"
    end

    test "subsequent packets of keyframe have N=0" do
      # Create a large keyframe that will be split into multiple packets
      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x06>> <> <<1, 2, 3, 4, 5, 6>>
      # Large frame to force fragmentation
      large_frame = <<0x32, 0xFF, 0x10>> <> :binary.copy(<<0xAA>>, 2000)

      keyframe = temporal_delimiter <> sequence_header <> large_frame

      packets =
        PayloadFormat.fragment(keyframe,
          mtu: 500,
          header_mode: :spec,
          fmtp: %{}
        )

      assert length(packets) > 1, "Should create multiple packets"

      # First packet: N=1
      [first | rest] = packets
      assert {:ok, first_header, _} = FullHeader.decode(first)
      assert first_header.n == true, "First packet must have N=1"

      # All subsequent packets: N=0
      Enum.each(rest, fn packet ->
        assert {:ok, header, _} = FullHeader.decode(packet)
        assert header.n == false, "Subsequent packets must have N=0"
      end)
    end

    test "delta frame (no sequence header) has N=0 on all packets" do
      # Create a delta frame: Temporal Delimiter + Frame (no sequence header)
      temporal_delimiter = <<0x12, 0x00>>
      frame = <<0x32, 0x0A>> <> :binary.copy(<<0xBB>>, 10)

      delta_frame = temporal_delimiter <> frame

      packets =
        PayloadFormat.fragment(delta_frame,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{}
        )

      assert is_list(packets)

      # All packets should have N=0
      Enum.each(packets, fn packet ->
        assert {:ok, header, _} = FullHeader.decode(packet)
        assert header.n == false, "Delta frame packets must have N=0"
      end)
    end

    test "large delta frame split across packets has N=0 on all" do
      # Large delta frame without sequence header
      temporal_delimiter = <<0x12, 0x00>>
      large_frame = <<0x32, 0xFF, 0x08>> <> :binary.copy(<<0xCC>>, 1500)

      delta_frame = temporal_delimiter <> large_frame

      packets =
        PayloadFormat.fragment(delta_frame,
          mtu: 500,
          header_mode: :spec,
          fmtp: %{}
        )

      assert length(packets) > 1

      # All packets should have N=0 (no sequence header)
      Enum.each(packets, fn packet ->
        assert {:ok, header, _} = FullHeader.decode(packet)
        assert header.n == false, "All delta frame packets must have N=0"
      end)
    end

    @tag :skip
    test "fragmented sequence header OBU: first packet N=1, rest N=0" do
      # Create OBU-aware access unit with very large sequence header
      temporal_delimiter = <<0x12, 0x00>>
      # Large sequence header that will be fragmented
      large_seq_header = <<0x0A, 0xFF, 0x08>> <> :binary.copy(<<0x11>>, 1500)

      keyframe = temporal_delimiter <> large_seq_header

      packets =
        PayloadFormat.fragment(keyframe,
          mtu: 500,
          header_mode: :spec,
          fmtp: %{}
        )

      assert length(packets) > 1

      [first | rest] = packets

      # First fragment: N=1
      assert {:ok, first_header, _} = FullHeader.decode(first)
      assert first_header.n == true, "First fragment of sequence header must have N=1"

      # Subsequent fragments: N=0
      Enum.each(rest, fn packet ->
        assert {:ok, header, _} = FullHeader.decode(packet)
        assert header.n == false, "Subsequent fragments must have N=0"
      end)
    end

    test "multiple OBUs in single packet: N=1 if contains sequence header" do
      # Small keyframe that fits in one packet
      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x02>> <> <<55, 66>>
      small_frame = <<0x32, 0x03>> <> <<77, 88, 99>>

      keyframe = temporal_delimiter <> sequence_header <> small_frame

      packets =
        PayloadFormat.fragment(keyframe,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{}
        )

      # Should fit in single packet
      assert length(packets) == 1

      # Single packet should have N=1 (contains sequence header)
      [packet] = packets
      assert {:ok, header, _} = FullHeader.decode(packet)
      assert header.n == true, "Packet containing sequence header must have N=1"
    end

    test "frame without temporal delimiter still sets N bit correctly" do
      # Just sequence header + frame (no temporal delimiter)
      sequence_header = <<0x0A, 0x03>> <> <<10, 20, 30>>
      frame = <<0x32, 0x04>> <> <<40, 50, 60, 70>>

      access_unit = sequence_header <> frame

      packets =
        PayloadFormat.fragment(access_unit,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{}
        )

      assert is_list(packets)
      [first | _] = packets

      assert {:ok, header, _} = FullHeader.decode(first)
      assert header.n == true, "First packet with sequence header must have N=1"
    end
  end

  describe "N bit with fragment_with_markers" do
    test "N bit set correctly with TU-aware marker assignment" do
      # Keyframe with sequence header
      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x04>> <> <<1, 2, 3, 4>>
      frame = <<0x32, 0x06>> <> <<5, 6, 7, 8, 9, 10>>

      keyframe = temporal_delimiter <> sequence_header <> frame

      packets_with_markers =
        PayloadFormat.fragment_with_markers(keyframe,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{},
          tu_aware: true
        )

      assert is_list(packets_with_markers)

      [{first_packet, _marker} | _rest] = packets_with_markers

      # First packet should have N=1
      assert {:ok, header, _} = FullHeader.decode(first_packet)
      assert header.n == true, "First packet must have N=1"
    end

    test "delta frame with markers has N=0" do
      # Delta frame
      temporal_delimiter = <<0x12, 0x00>>
      frame = <<0x32, 0x05>> <> <<11, 12, 13, 14, 15>>

      delta_frame = temporal_delimiter <> frame

      packets_with_markers =
        PayloadFormat.fragment_with_markers(delta_frame,
          mtu: 1200,
          header_mode: :spec,
          fmtp: %{},
          tu_aware: true
        )

      # All packets should have N=0
      Enum.each(packets_with_markers, fn {packet, _marker} ->
        assert {:ok, header, _} = FullHeader.decode(packet)
        assert header.n == false, "Delta frame must have N=0"
      end)
    end
  end

  describe "N bit NOT used in draft mode" do
    test "draft mode ignores N bit parameter" do
      # In draft mode, N bit is not part of the header format
      # This test verifies that draft mode continues to work

      temporal_delimiter = <<0x12, 0x00>>
      sequence_header = <<0x0A, 0x03>> <> <<1, 2, 3>>
      frame = <<0x32, 0x04>> <> <<4, 5, 6, 7>>

      keyframe = temporal_delimiter <> sequence_header <> frame

      packets =
        PayloadFormat.fragment(keyframe,
          mtu: 1200,
          header_mode: :draft,
          fmtp: %{}
        )

      assert is_list(packets)
      assert length(packets) >= 1
      # Draft mode doesn't have N bit, so we just verify it doesn't crash
    end
  end
end
