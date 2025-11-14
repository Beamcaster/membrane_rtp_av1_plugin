defmodule Membrane.RTP.AV1.FragmentTimeoutTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{Depayloader, FullHeader}

  @moduletag :fragment_timeout

  describe "fragment timeout detection" do
    setup do
      # Initialize depayloader with 100ms timeout for faster tests
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90000,
          header_mode: :spec,
          fragment_timeout_ms: 100
        })

      # Initialize sequence tracker
      state = %{state | seq_tracker: %{state.seq_tracker | last_seq: 99, initialized?: true}}

      {:ok, state: state}
    end

    test "emits timeout event when fragment is not completed within timeout", %{state: state} do
      # Attach telemetry handler to capture timeout events
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-fragment-timeout-#{inspect(ref)}",
        [:membrane_rtp_av1, :depayloader, :fragment_timeout],
        fn event_name, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      # Create W=1 packet (start of fragment)
      full_header = %FullHeader{
        w: 1,
        y: true,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload1 = FullHeader.encode(full_header) <> <<1, 2, 3>>

      buffer1 = %Membrane.Buffer{
        payload: payload1,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 100}}
      }

      # Process W=1 packet - should start timer
      {[], state} = Depayloader.handle_buffer(:input, buffer1, nil, state)

      # Verify fragment accumulator has data
      assert state.frag_acc == <<1, 2, 3>>
      assert state.fragment_timer_ref != nil
      assert state.fragment_start_time != nil

      # Wait for timeout (100ms + margin)
      Process.sleep(150)

      # Trigger timeout by sending message
      send(self(), :fragment_timeout)
      {actions, state} = Depayloader.handle_info(:fragment_timeout, nil, state)

      # Verify discontinuity event was emitted
      assert length(actions) == 1
      assert [{:event, {:output, %Membrane.Event.Discontinuity{}}}] = actions

      # Verify fragment state was reset
      assert state.frag_acc == []
      assert state.fragment_timer_ref == nil
      assert state.fragment_start_time == nil

      # Verify telemetry event was emitted
      assert_received {:telemetry_event, [:membrane_rtp_av1, :depayloader, :fragment_timeout],
                       measurements, metadata}

      assert measurements.fragment_age_ms >= 0
      assert measurements.accumulated_bytes == 3
      assert metadata.reason == :timeout

      :telemetry.detach("test-fragment-timeout-#{inspect(ref)}")
    end

    test "cancels timer when W=3 completes fragment before timeout", %{state: state} do
      # Create W=1 packet (start of fragment)
      full_header1 = %FullHeader{
        w: 1,
        y: true,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload1 = FullHeader.encode(full_header1) <> <<1, 2, 3>>

      buffer1 = %Membrane.Buffer{
        payload: payload1,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 100}}
      }

      # Process W=1 - starts timer
      {[], state} = Depayloader.handle_buffer(:input, buffer1, nil, state)
      assert state.fragment_timer_ref != nil

      # Create W=3 packet (end of fragment)
      full_header3 = %FullHeader{
        w: 3,
        y: false,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload3 = FullHeader.encode(full_header3) <> <<4, 5, 6>>

      buffer3 = %Membrane.Buffer{
        payload: payload3,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 101, marker: true}}
      }

      # Process W=3 - should cancel timer and complete fragment
      {actions, state} = Depayloader.handle_buffer(:input, buffer3, nil, state)

      # Verify timer was canceled
      assert state.fragment_timer_ref == nil
      assert state.fragment_start_time == nil

      # Verify fragment was completed (buffer emitted)
      assert length(actions) >= 1

      assert Enum.any?(actions, fn
               {:buffer, _} -> true
               _ -> false
             end)

      # Verify fragment accumulator was reset
      assert state.frag_acc == []

      # Wait to ensure timeout doesn't fire
      Process.sleep(150)

      # Verify no timeout occurred
      refute_received :fragment_timeout
    end

    test "timeout with no fragments accumulated is handled gracefully (race condition)", %{
      state: state
    } do
      # Simulate race condition: timeout fires but fragments already cleared
      state = %{
        state
        | frag_acc: [],
          fragment_timer_ref: make_ref(),
          fragment_start_time: System.monotonic_time(:millisecond)
      }

      {actions, new_state} = Depayloader.handle_info(:fragment_timeout, nil, state)

      # No discontinuity event should be emitted (no fragments were accumulated)
      assert actions == []

      # Timer refs should be cleared
      assert new_state.fragment_timer_ref == nil
      assert new_state.fragment_start_time == nil
    end

    test "multiple consecutive timeouts are handled correctly", %{state: state} do
      test_pid = self()
      ref = make_ref()

      timeout_count = :counters.new(1, [])

      :telemetry.attach(
        "test-multiple-timeouts-#{inspect(ref)}",
        [:membrane_rtp_av1, :depayloader, :fragment_timeout],
        fn _, _, _, _ ->
          :counters.add(timeout_count, 1, 1)
        end,
        nil
      )

      # First incomplete fragment
      full_header1 = %FullHeader{
        w: 1,
        y: true,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload1 = FullHeader.encode(full_header1) <> <<1, 2, 3>>

      buffer1 = %Membrane.Buffer{
        payload: payload1,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 100}}
      }

      {[], state} = Depayloader.handle_buffer(:input, buffer1, nil, state)

      # Trigger first timeout
      send(self(), :fragment_timeout)
      {_, state} = Depayloader.handle_info(:fragment_timeout, nil, state)

      # Second incomplete fragment
      full_header2 = %FullHeader{
        w: 1,
        y: true,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload2 = FullHeader.encode(full_header2) <> <<4, 5, 6>>

      buffer2 = %Membrane.Buffer{
        payload: payload2,
        pts: 2000,
        metadata: %{rtp: %{sequence_number: 105}}
      }

      {[], state} = Depayloader.handle_buffer(:input, buffer2, nil, state)

      # Trigger second timeout
      send(self(), :fragment_timeout)
      {_, _state} = Depayloader.handle_info(:fragment_timeout, nil, state)

      # Verify both timeouts were recorded
      assert :counters.get(timeout_count, 1) == 2

      :telemetry.detach("test-multiple-timeouts-#{inspect(ref)}")
    end

    test "timeout is canceled when gap is detected during fragmentation", %{state: state} do
      # Start fragment
      full_header1 = %FullHeader{
        w: 1,
        y: true,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload1 = FullHeader.encode(full_header1) <> <<1, 2, 3>>

      buffer1 = %Membrane.Buffer{
        payload: payload1,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 100}}
      }

      {[], state} = Depayloader.handle_buffer(:input, buffer1, nil, state)
      assert state.fragment_timer_ref != nil

      # Gap detected - sequence number jumps
      full_header2 = %FullHeader{
        w: 2,
        y: false,
        temporal_id: 0,
        spatial_id: 0,
        z: false,
        n: false,
        scalability_structure: nil
      }

      payload2 = FullHeader.encode(full_header2) <> <<4, 5, 6>>
      # Gap!
      buffer2 = %Membrane.Buffer{
        payload: payload2,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 110}}
      }

      {[], state} = Depayloader.handle_buffer(:input, buffer2, nil, state)

      # Verify timer was canceled (gap detection resets fragments)
      assert state.fragment_timer_ref == nil
      assert state.fragment_start_time == nil
      assert state.frag_acc == []
    end
  end
end
