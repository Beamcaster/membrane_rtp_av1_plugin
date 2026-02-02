defmodule Membrane.RTP.AV1.Depayloader.GStreamerTest do
  @moduledoc """
  Tests for GStreamer AV1 RTP payloading support.

  GStreamer sends RTP packets with:
  - N=0 (never sets N bit for keyframes)
  - OBUs without obu_has_size_field (has_size=0)

  This differs from OBS which typically:
  - Sets N=1 for keyframes
  - Sends OBUs with obu_has_size_field=1
  """

  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.RTP.AV1.Depayloader.State
  alias Membrane.AV1.LEB128
  alias Membrane.Buffer

  import Membrane.RTP.AV1.TestHelperUtils

  # OBU type constants
  @obu_sequence_header 1
  @obu_frame_header 3
  @obu_frame 6

  describe "GStreamer payloading (N=0, OBUs without size fields)" do
    test "handles W=1 packet with single FRAME_HEADER OBU (no false sequence header detection)" do
      # GStreamer sends small packets like <<16, 24, 232>> for frame headers
      # W=1, N=0, single OBU without size field
      # OBU header 0x18 = type 3 (FRAME_HEADER), has_size=0
      # FRAME_HEADER without size field
      frame_header_obu = <<0x18, 0xE8>>
      payload = build_aggregation_header(w: 1, n: 0) <> frame_header_obu

      state = init_depayloader()
      buffer = build_rtp_buffer(payload, marker: true, timestamp: 1000)

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should NOT falsely detect a sequence header
      # The 0xE8 byte should NOT be mistaken for an OBU header
      refute has_false_sequence_header_detection?(actions)
    end

    test "handles W=2 packet with FRAME OBUs containing bytes that look like OBU headers" do
      # This is the critical test case: frame data contains bytes like 0x0A
      # which look like SEQUENCE_HEADER OBU headers (type=1, has_size=1)
      # The depayloader should NOT misdetect these as actual sequence headers

      # Create a FRAME OBU (type 6, has_size=0) with content that includes
      # bytes that would be misdetected as OBU headers by heuristic scanning
      # Bytes that look like OBU headers
      frame_content = <<0x0A, 0x0B, 0x08, 0x09, 0x18>>
      # 0x30 = FRAME, has_size=0
      frame_obu = <<0x30>> <> frame_content

      # Second OBU: another FRAME
      frame2_content = :crypto.strong_rand_bytes(10)
      frame2_obu = <<0x30>> <> frame2_content

      # W=2: first OBU has LEB128 length, second extends to end
      first_obu_len = byte_size(frame_obu)

      payload =
        build_aggregation_header(w: 2, n: 0) <>
          LEB128.encode(first_obu_len) <>
          frame_obu <>
          frame2_obu

      state = init_depayloader()
      buffer = build_rtp_buffer(payload, marker: true, timestamp: 1000)

      {actions, new_state} = Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should NOT falsely detect a sequence header from the 0x0A, 0x0B bytes
      # Since there's no real sequence header, it should either:
      # 1. Request a keyframe (PLI)
      # 2. Or output nothing (waiting for keyframe)
      refute new_state.keyframe_established,
             "Should not establish keyframe from false sequence header detection"
    end

    test "correctly detects real SEQUENCE_HEADER in GStreamer packet" do
      # Build a packet with actual SEQUENCE_HEADER OBU (type 1)
      # OBU header: 0x0A = type 1, has_size=1 (this is a REAL sequence header)
      # Minimal valid sequence header content
      seq_header_content = build_minimal_sequence_header()
      seq_header_obu = <<0x0A, byte_size(seq_header_content)>> <> seq_header_content

      # FRAME OBU following the sequence header
      frame_content = :crypto.strong_rand_bytes(20)
      # 0x32 = FRAME with has_size=1
      frame_obu = <<0x32, byte_size(frame_content)>> <> frame_content

      # W=2, N=0 (GStreamer doesn't set N even for keyframes)
      payload =
        build_aggregation_header(w: 2, n: 0) <>
          LEB128.encode(byte_size(seq_header_obu)) <>
          seq_header_obu <>
          frame_obu

      state = init_depayloader()
      buffer = build_rtp_buffer(payload, marker: true, timestamp: 1000)

      {actions, new_state} = Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should detect the real sequence header and establish keyframe
      assert new_state.keyframe_established,
             "Should establish keyframe when real sequence header is present"

      assert has_buffer_output?(actions),
             "Should output buffer when keyframe is established"
    end

    test "handles W=3 packet correctly" do
      # GStreamer sometimes sends W=3 packets
      # Build 3 OBUs: FRAME_HEADER + TILE_GROUP would be typical
      # FRAME_HEADER, no size
      obu1 = <<0x18, 0xAA, 0xBB>>
      # TILE_GROUP (type 4), no size
      obu2 = <<0x20, 0xCC, 0xDD>>
      # FRAME, no size
      obu3 = <<0x30, 0xEE, 0xFF>>

      # W=3: first 2 have LEB128 lengths, third extends to end
      payload =
        build_aggregation_header(w: 3, n: 0) <>
          LEB128.encode(byte_size(obu1)) <>
          obu1 <>
          LEB128.encode(byte_size(obu2)) <>
          obu2 <>
          obu3

      state = init_depayloader()
      buffer = build_rtp_buffer(payload, marker: true, timestamp: 1000)

      # Should not crash and should handle the packet
      {_actions, _new_state} = Depayloader.handle_buffer(:input, buffer, %{}, state)
    end
  end

  describe "OBS payloading (N=1, OBUs with size fields) - regression tests" do
    test "handles N=1 keyframe with sequence header" do
      # OBS-style: N=1 for keyframes, OBUs have size fields
      seq_header_content = build_minimal_sequence_header()
      seq_header_obu = <<0x0A, byte_size(seq_header_content)>> <> seq_header_content

      frame_content = :crypto.strong_rand_bytes(20)
      frame_obu = <<0x32, byte_size(frame_content)>> <> frame_content

      # W=0 with N=1 (OBS typically uses W=0 with length-prefixed OBUs)
      payload =
        build_aggregation_header(w: 0, n: 1) <>
          LEB128.encode(byte_size(seq_header_obu)) <>
          seq_header_obu <>
          LEB128.encode(byte_size(frame_obu)) <>
          frame_obu

      state = init_depayloader()
      buffer = build_rtp_buffer(payload, marker: true, timestamp: 1000)

      {actions, new_state} = Depayloader.handle_buffer(:input, buffer, %{}, state)

      assert new_state.keyframe_established,
             "OBS-style N=1 keyframe should be detected"

      assert has_buffer_output?(actions)
    end

    test "handles inter frame after keyframe established" do
      # First, establish keyframe
      seq_header_content = build_minimal_sequence_header()
      seq_header_obu = <<0x0A, byte_size(seq_header_content)>> <> seq_header_content
      frame_content = :crypto.strong_rand_bytes(20)
      frame_obu = <<0x32, byte_size(frame_content)>> <> frame_content

      keyframe_payload =
        build_aggregation_header(w: 0, n: 1) <>
          LEB128.encode(byte_size(seq_header_obu)) <>
          seq_header_obu <>
          LEB128.encode(byte_size(frame_obu)) <>
          frame_obu

      state = init_depayloader()
      keyframe_buffer = build_rtp_buffer(keyframe_payload, marker: true, timestamp: 1000)
      {_actions, state} = Depayloader.handle_buffer(:input, keyframe_buffer, %{}, state)

      # Now send inter frame (no sequence header, N=0)
      inter_frame_content = :crypto.strong_rand_bytes(15)
      inter_frame_obu = <<0x32, byte_size(inter_frame_content)>> <> inter_frame_content

      inter_payload =
        build_aggregation_header(w: 1, n: 0) <>
          inter_frame_obu

      inter_buffer = build_rtp_buffer(inter_payload, marker: true, timestamp: 2000)
      {actions, new_state} = Depayloader.handle_buffer(:input, inter_buffer, %{}, state)

      assert new_state.keyframe_established,
             "Keyframe should remain established"

      assert has_buffer_output?(actions),
             "Inter frame should be output after keyframe established"
    end
  end

  # Helper functions

  defp init_depayloader do
    %State{
      require_sequence_header: true,
      max_reorder_buffer: 10
    }
  end

  defp build_rtp_buffer(payload, opts) do
    %Buffer{
      payload: payload,
      pts: Keyword.get(opts, :pts),
      metadata: %{
        rtp: %{
          timestamp: Keyword.fetch!(opts, :timestamp),
          marker: Keyword.get(opts, :marker, false),
          sequence_number: Keyword.get(opts, :seq, 1),
          ssrc: 12345,
          payload_type: 96
        }
      }
    }
  end

  defp build_aggregation_header(opts) do
    z = Keyword.get(opts, :z, 0)
    y = Keyword.get(opts, :y, 0)
    w = Keyword.get(opts, :w, 0)
    n = Keyword.get(opts, :n, 0)

    # Format: Z(1) Y(1) W(2) N(1) reserved(3)
    <<z::1, y::1, w::2, n::1, 0::3>>
  end

  defp build_minimal_sequence_header do
    # Minimal AV1 sequence header content (not fully valid but enough for testing)
    # seq_profile, seq_level_idx, etc.
    <<0x00, 0x00, 0x00, 0x00, 0x00>>
  end

  defp has_false_sequence_header_detection?(actions) do
    # If keyframe was established without a real sequence header,
    # that indicates false detection
    Enum.any?(actions, fn
      {:buffer, {_pad, %Buffer{metadata: %{av1: %{key_frame?: true}}}}} -> true
      _ -> false
    end)
  end
end
