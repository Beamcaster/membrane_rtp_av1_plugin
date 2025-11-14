defmodule Membrane.RTP.AV1.FragmentDiscontinuityTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Membrane.RTP.AV1.{Depayloader, FullHeader}
  alias Membrane.Buffer
  import Membrane.RTP.AV1.TestHelperUtils

  describe "fragment discontinuity detection" do
    setup do
      {[], state} = Depayloader.handle_init(nil, %{clock_rate: 90_000, header_mode: :spec})
      # handle_stream_format now returns stream_format action - discard it for unit tests
      {_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      # Attach telemetry handler to capture discontinuity events
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-discontinuity-#{inspect(ref)}",
        [:membrane_rtp_av1, :depayloader, :discontinuity],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-discontinuity-#{inspect(ref)}")
      end)

      {:ok, state: state}
    end

    defp encode_full_header(w_value, y_flag, _n_flag, obu_count) do
      header = %FullHeader{
        z: false,
        y: y_flag,
        w: w_value,
        n: obu_count > 1,
        c: obu_count,
        m: false
      }

      FullHeader.encode(header)
    end

    defp handle_buffer_with_seq(state, payload, pts, marker, seq_num) do
      metadata = %{
        rtp: %{
          marker: marker,
          sequence_number: seq_num
        }
      }

      buffer = %Buffer{payload: payload, pts: pts, metadata: metadata}
      Depayloader.handle_buffer(:input, buffer, nil, state)
    end

    test "detects gap during W=1→W=2 sequence", %{state: state} do
      # W=1: First fragment (seq 100)
      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2>>
      {[], state} = handle_buffer_with_seq(state, payload1, 1000, false, 100)

      # Gap: skip seq 101, jump to seq 105 (gap of 4 packets)
      # W=2: Middle fragment should trigger discontinuity detection
      payload2 = encode_full_header(2, false, false, 1) <> <<3, 4>>
      {[], state} = handle_buffer_with_seq(state, payload2, 2000, false, 105)

      # Verify telemetry event was emitted
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity],
                       %{gap_size: 4}, %{reason: :sequence_gap_during_fragmentation}}

      # Verify state was reset (frag_acc should be empty)
      # Zero-copy: acc and frag_acc are now IO lists
      assert state.frag_acc == []
      assert state.acc == []

      # New fragment sequence should work after reset
      payload3 = encode_full_header(1, true, false, 1) <> <<5, 6>>
      payload4 = encode_full_header(3, false, false, 1) <> <<7, 8>>

      {[], state} = handle_buffer_with_seq(state, payload3, 3000, false, 106)

      {actions, _state} =
        handle_buffer_with_seq(state, payload4, 4000, true, 107)

      buffer = first_output_buffer(actions)

      assert buffer.payload == <<5, 6, 7, 8>>
    end

    test "detects gap during W=2→W=3 sequence", %{state: state} do
      # Complete W=1→W=2 sequence
      payload1 = encode_full_header(1, true, false, 1) <> <<1>>
      payload2 = encode_full_header(2, false, false, 1) <> <<2>>

      {[], state} = handle_buffer_with_seq(state, payload1, 1000, false, 200)
      {[], state} = handle_buffer_with_seq(state, payload2, 2000, false, 201)

      # Gap before W=3
      payload3 = encode_full_header(3, false, false, 1) <> <<3>>
      {[], state} = handle_buffer_with_seq(state, payload3, 3000, false, 210)

      # Verify discontinuity detected
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity],
                       %{gap_size: 8}, %{reason: :sequence_gap_during_fragmentation}}

      # Verify state was reset
      # Zero-copy: acc and frag_acc are now IO lists
      assert state.frag_acc == []
      assert state.acc == []
    end

    test "no discontinuity on gap during W=0 (non-fragmented)", %{state: state} do
      # W=0 packet (seq 300)
      payload1 = encode_full_header(0, true, false, 1) <> <<1, 2, 3>>
      {[], state} = handle_buffer_with_seq(state, payload1, 1000, false, 300)

      # Gap to seq 305 during W=0 should not trigger discontinuity event
      payload2 = encode_full_header(0, true, false, 1) <> <<4, 5, 6>>

      {actions, _state} =
        handle_buffer_with_seq(state, payload2, 2000, true, 305)

      assert has_buffer_output?(actions)

      # Verify NO discontinuity event was emitted (only warning logged)
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity], _, _}
    end

    test "handles multiple gap events in same stream", %{state: state} do
      # First fragment with gap
      payload1 = encode_full_header(1, true, false, 1) <> <<1>>
      {[], state} = handle_buffer_with_seq(state, payload1, 1000, false, 400)

      payload2 = encode_full_header(2, false, false, 1) <> <<2>>
      {[], state} = handle_buffer_with_seq(state, payload2, 2000, false, 405)

      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity], _, _}

      # Second fragment with another gap
      payload3 = encode_full_header(1, true, false, 1) <> <<3>>
      {[], state} = handle_buffer_with_seq(state, payload3, 3000, false, 406)

      payload4 = encode_full_header(2, false, false, 1) <> <<4>>
      {[], _state} = handle_buffer_with_seq(state, payload4, 4000, false, 412)

      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity], _, _}
    end

    test "gap at W=1 start doesn't trigger discontinuity (no prior fragment)", %{state: state} do
      # First packet ever, seq 500
      payload1 = encode_full_header(1, true, false, 1) <> <<1>>
      {[], state} = handle_buffer_with_seq(state, payload1, 1000, false, 500)

      # Gap to seq 510 for W=2 - this SHOULD trigger discontinuity since we're now in W=1
      payload2 = encode_full_header(2, false, false, 1) <> <<2>>
      {[], _state} = handle_buffer_with_seq(state, payload2, 2000, false, 510)

      # Should receive discontinuity event
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :discontinuity], _, _}
    end
  end
end
