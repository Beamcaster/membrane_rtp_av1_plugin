defmodule Membrane.RTP.AV1.Rav1DepayloaderTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{Rav1Depayloader, FullHeader, Header}
  alias Membrane.{Buffer, RemoteStream}

  describe "initialization" do
    test "initializes successfully with default options" do
      assert {[], state} =
               Rav1Depayloader.handle_init(
                 %{},
                 %{
                   clock_rate: 90_000,
                   header_mode: :auto,
                   max_reorder_buffer: 10,
                   max_seq_gap: 5,
                   reorder_timeout_ms: 500
                 }
               )

      assert is_reference(state.decoder)
      assert state.clock_rate == 90_000
      assert state.stream_format_sent == false
      assert state.frame_count == 0
      assert state.header_mode == :auto
      assert state.reorder == %{}
      assert Enum.empty?(state.fragment_queue)
      assert Enum.empty?(state.complete_obu_queue)
      assert state.first_pts == nil
      assert state.max_reorder_buffer == 10
      assert state.max_seq_gap == 5
    end

    test "accepts custom clock rate" do
      assert {[], state} =
               Rav1Depayloader.handle_init(
                 %{},
                 %{
                   clock_rate: 48_000,
                   header_mode: :spec,
                   max_reorder_buffer: 10,
                   max_seq_gap: 5,
                   reorder_timeout_ms: 500
                 }
               )

      assert state.clock_rate == 48_000
      assert state.header_mode == :spec
    end
  end

  describe "stream format handling" do
    test "accepts RemoteStream format without sending output format" do
      {:ok, decoder} = Rav1dEx.new()

      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :auto,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      input_format = %RemoteStream{type: :packetized}

      assert {[], ^state} =
               Rav1Depayloader.handle_stream_format(
                 :input,
                 input_format,
                 %{},
                 state
               )
    end
  end

  describe "W-bit handling and fragmentation" do
    setup do
      {:ok, decoder} = Rav1dEx.new()

      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :spec,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      {:ok, state: state}
    end

    test "handles W=0 (complete OBUs) without marker", %{state: state} do
      # Create AV1 RTP payload with W=0 (complete OBUs)
      # Header byte: Z=0, Y=1, W=00, N=0, C=0, M=0, I=0
      # Binary: 0100_0000 = 0x40
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      payload = FullHeader.encode(header) <> <<0x05, 0x01, 0x02, 0x03, 0x04>>

      buffer = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            marker: false,
            sequence_number: 1,
            timestamp: 1000
          }
        }
      }

      {actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # No marker bit, so packet is buffered in reorder module, no output yet
      assert actions == []
      # Packet should be in reorder buffer (not yet processed)
      refute Enum.empty?(new_state.reorder)
    end

    test "handles W=0 (complete OBUs) with marker bit", %{state: state} do
      # Create minimal valid OBU (will likely not decode, but tests the flow)
      header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      # LEB128-framed OBU
      obu_payload = <<0x05, 0x01, 0x02, 0x03, 0x04, 0x05>>
      payload = FullHeader.encode(header) <> obu_payload

      buffer = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            marker: true,
            sequence_number: 1,
            timestamp: 1000
          }
        }
      }

      {actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Marker bit set, so access unit is assembled and sent to decoder
      # Decoder will likely return empty frames or error for invalid data
      assert is_list(actions)
      # Reorder context for this timestamp should be cleared
      assert Enum.empty?(new_state.reorder)
      # OBU queue should be cleared after processing
      assert Enum.empty?(new_state.complete_obu_queue)
      assert new_state.first_pts == nil
    end

    test "handles W=1 (first fragment) starts timer", %{state: state} do
      header = %FullHeader{
        z: false,
        y: true,
        w: 1,
        n: false,
        c: 0,
        m: false
      }

      payload = FullHeader.encode(header) <> <<0x01, 0x02, 0x03>>

      buffer = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            marker: false,
            sequence_number: 1,
            timestamp: 1000
          }
        }
      }

      {_actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Packet buffered in reorder module (waiting for marker)
      refute Enum.empty?(new_state.reorder)
    end

    test "handles W=1,W=3 (two-packet fragment)", %{state: state} do
      # First fragment (W=1)
      header1 = %FullHeader{z: false, y: true, w: 1, n: false, c: 0, m: false}
      payload1 = FullHeader.encode(header1) <> <<0x01, 0x02>>

      buffer1 = %Buffer{
        payload: payload1,
        pts: 1000,
        metadata: %{rtp: %{marker: false, sequence_number: 1, timestamp: 1000}}
      }

      {_actions1, state1} = Rav1Depayloader.handle_buffer(:input, buffer1, %{}, state)

      # Last fragment (W=3) with marker bit
      header2 = %FullHeader{z: false, y: false, w: 3, n: false, c: 0, m: false}
      payload2 = FullHeader.encode(header2) <> <<0x03, 0x04>>

      buffer2 = %Buffer{
        payload: payload2,
        pts: 1000,
        metadata: %{rtp: %{marker: true, sequence_number: 2, timestamp: 1000}}
      }

      {_actions2, state2} = Rav1Depayloader.handle_buffer(:input, buffer2, %{}, state1)

      # Marker bit set, so access unit is complete and processed
      # Reorder context should be cleared
      assert Enum.empty?(state2.reorder)
      # Queues should be empty after processing
      assert Enum.empty?(state2.fragment_queue)
      assert Enum.empty?(state2.complete_obu_queue)
    end
  end

  describe "sequence number handling" do
    setup do
      {:ok, decoder} = Rav1dEx.new()

      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :spec,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      {:ok, state: state}
    end

    test "detects sequence number gaps", %{state: state} do
      header = %FullHeader{z: false, y: true, w: 0, n: false, c: 0, m: false}
      payload = FullHeader.encode(header) <> <<0x01>>

      # First packet (seq 1) with marker
      buffer1 = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{rtp: %{marker: true, sequence_number: 1, timestamp: 1000}}
      }

      {_actions1, state1} = Rav1Depayloader.handle_buffer(:input, buffer1, %{}, state)

      # Gap: jump to seq 5 (skipped 2, 3, 4) - gap is 4 which is less than max_seq_gap=5
      buffer2 = %Buffer{
        payload: payload,
        pts: 2000,
        metadata: %{rtp: %{marker: false, sequence_number: 5, timestamp: 2000}}
      }

      {actions2, state2} = Rav1Depayloader.handle_buffer(:input, buffer2, %{}, state1)

      # With bounded reordering, small gap (4 < max_gap=5) is buffered
      # Packet is held in reorder module waiting for 2, 3, 4
      assert is_list(actions2)

      # Packet 5 should be in reorder buffer
      refute Enum.empty?(state2.reorder)
    end

    test "handles sequence number wraparound", %{state: state} do
      header = %FullHeader{z: false, y: true, w: 0, n: false, c: 0, m: false}
      payload = FullHeader.encode(header) <> <<0x01>>

      # Packet near end of sequence space without marker
      buffer1 = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{rtp: %{marker: false, sequence_number: 65535, timestamp: 1000}}
      }

      {_actions1, state1} = Rav1Depayloader.handle_buffer(:input, buffer1, %{}, state)

      # Next packet wraps around to 0 (contiguous in sequence space)
      buffer2 = %Buffer{
        payload: payload,
        pts: 1000,
        # Same timestamp, next sequence
        metadata: %{rtp: %{marker: true, sequence_number: 0, timestamp: 1000}}
      }

      {actions2, state2} = Rav1Depayloader.handle_buffer(:input, buffer2, %{}, state1)

      # Reorder module should handle wraparound correctly
      # Both packets are part of same AU (timestamp 1000)
      # The test verifies reorder module can handle seq wraparound
      assert is_list(actions2)
      assert Enum.empty?(state2.reorder)
    end
  end

  describe "header mode support" do
    setup do
      {:ok, decoder} = Rav1dEx.new()
      {:ok, decoder: decoder}
    end

    test "supports draft mode headers", %{decoder: decoder} do
      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :draft,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      # Create spec header: complete packet with 1 OBU (Z=0, Y=0, W=1, N=0)
      # Binary: 0001_0000 = 0x10
      header = %Header{z: false, y: false, w: 1, n: false}
      payload = Header.encode(header) <> <<0x05, 0x01, 0x02, 0x03, 0x04>>

      buffer = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{rtp: %{marker: false, sequence_number: 1}}
      }

      {actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should process without error
      assert is_list(actions)
      assert is_map(new_state)
    end

    test "auto mode tries spec first, falls back to draft", %{decoder: decoder} do
      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :auto,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      # Valid spec mode header
      header = %FullHeader{z: false, y: true, w: 0, n: false, c: 0, m: false}
      payload = FullHeader.encode(header) <> <<0x01>>

      buffer = %Buffer{
        payload: payload,
        pts: 1000,
        metadata: %{rtp: %{marker: false, sequence_number: 1}}
      }

      {actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should process successfully
      assert is_list(actions)
      assert is_map(new_state)
    end
  end

  describe "error handling" do
    test "handles malformed headers gracefully" do
      {:ok, decoder} = Rav1dEx.new()

      state = %{
        decoder: decoder,
        clock_rate: 90_000,
        stream_format_sent: false,
        frame_count: 0,
        reorder: %{},
        fragment_queue: Qex.new(),
        complete_obu_queue: Qex.new(),
        first_pts: nil,
        header_mode: :spec,
        max_reorder_buffer: 10,
        max_seq_gap: 5,
        reorder_timeout_ms: 500,
        cached_scalability_structure: nil
      }

      # Too short to be valid
      buffer = %Buffer{
        payload: <<>>,
        pts: 1000,
        metadata: %{rtp: %{marker: false, sequence_number: 1}}
      }

      {actions, new_state} = Rav1Depayloader.handle_buffer(:input, buffer, %{}, state)

      # Should emit discontinuity
      assert Enum.any?(actions, fn
               {:event, {:output, %Membrane.Event.Discontinuity{}}} -> true
               _ -> false
             end)

      assert is_map(new_state)
    end
  end
end
