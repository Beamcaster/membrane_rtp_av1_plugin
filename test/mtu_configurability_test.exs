defmodule Membrane.RTP.AV1.MTUConfigurabilityTest do
  @moduledoc """
  Tests for MTU configurability in the AV1 RTP payloader.

  Validates:
  - Initial MTU configuration and validation
  - Dynamic MTU changes via MTUUpdateEvent
  - MTU clamping to safe range (64-9000 bytes)
  - Proper fragmentation with different MTU values
  - RTCP-driven MTU adaptation scenarios
  """
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.{Payloader, MTUUpdateEvent, OBU}

  describe "initial MTU configuration" do
    test "uses default MTU of 1200 bytes" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})
      assert state.mtu == 1200
    end

    test "accepts custom MTU within valid range" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1500})
      assert state.mtu == 1500
    end

    test "clamps MTU below minimum (64 bytes)" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 32})
      assert state.mtu == 64
    end

    test "clamps MTU above maximum (9000 bytes)" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 10_000})
      assert state.mtu == 9000
    end

    test "accepts minimum MTU (64 bytes)" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 64})
      assert state.mtu == 64
    end

    test "accepts maximum MTU (9000 bytes - jumbo frames)" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 9000})
      assert state.mtu == 9000
    end

    test "accepts typical Internet MTU (1500 bytes)" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1500})
      assert state.mtu == 1500
    end
  end

  describe "dynamic MTU updates via MTUUpdateEvent" do
    test "updates MTU when event is received" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})
      assert state.mtu == 1200

      event = %MTUUpdateEvent{mtu: 1500}
      {_actions, new_state} = Payloader.handle_event(:input, event, nil, state)

      assert new_state.mtu == 1500
    end

    test "clamps MTU to minimum when event has too small value" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})

      event = %MTUUpdateEvent{mtu: 32}
      {_actions, new_state} = Payloader.handle_event(:input, event, nil, state)

      assert new_state.mtu == 64
    end

    test "clamps MTU to maximum when event has too large value" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})

      event = %MTUUpdateEvent{mtu: 15_000}
      {_actions, new_state} = Payloader.handle_event(:input, event, nil, state)

      assert new_state.mtu == 9000
    end

    test "allows multiple MTU updates" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})

      # First update
      event1 = %MTUUpdateEvent{mtu: 800}
      {_actions, state} = Payloader.handle_event(:input, event1, nil, state)
      assert state.mtu == 800

      # Second update
      event2 = %MTUUpdateEvent{mtu: 1500}
      {_actions, state} = Payloader.handle_event(:input, event2, nil, state)
      assert state.mtu == 1500

      # Third update
      event3 = %MTUUpdateEvent{mtu: 9000}
      {_actions, state} = Payloader.handle_event(:input, event3, nil, state)
      assert state.mtu == 9000
    end

    test "ignores other events" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})

      # Some other event type
      {_actions, new_state} = Payloader.handle_event(:input, :some_other_event, nil, state)

      # MTU should remain unchanged
      assert new_state.mtu == 1200
    end
  end

  describe "fragmentation with different MTU values" do
    test "small MTU produces more packets" do
      obu = OBU.build_obu(:crypto.strong_rand_bytes(5_000))
      access_unit = IO.iodata_to_binary([obu])

      # Small MTU (256 bytes)
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 256})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      small_mtu_packets =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      small_count = length(small_mtu_packets)

      # Large MTU (1500 bytes)
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1500})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      large_mtu_packets =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      large_count = length(large_mtu_packets)

      # Small MTU should produce more packets
      assert small_count > large_count
    end

    test "jumbo frames MTU (9000) produces fewer packets" do
      # Large access unit
      obu = OBU.build_obu(:crypto.strong_rand_bytes(20_000))
      access_unit = IO.iodata_to_binary([obu])

      # Standard MTU (1200 bytes)
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      standard_packets =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      standard_count = length(standard_packets)

      # Jumbo frames MTU (9000 bytes)
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 9000})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      jumbo_packets =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      jumbo_count = length(jumbo_packets)

      # Jumbo frames should produce significantly fewer packets
      assert jumbo_count < standard_count
      # Should be roughly 7x fewer packets (9000 / 1200)
      assert standard_count / jumbo_count >= 5
    end

    test "MTU change affects subsequent buffers" do
      obu = OBU.build_obu(:crypto.strong_rand_bytes(5_000))
      access_unit = IO.iodata_to_binary([obu])

      # Start with small MTU
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 300})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      # First buffer with small MTU
      {actions1, state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      packets1 =
        actions1
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      count1 = length(packets1)

      # Update MTU to larger value
      event = %MTUUpdateEvent{mtu: 1500}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)

      # Second buffer with large MTU
      {actions2, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 2_000_000}, nil, state)

      packets2 =
        actions2
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      count2 = length(packets2)

      # Second buffer should produce fewer packets due to larger MTU
      assert count2 < count1
    end
  end

  describe "RTCP-driven MTU adaptation scenarios" do
    test "high packet loss scenario: reduce MTU" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1500})
      assert state.mtu == 1500

      # Simulate RTCP feedback indicating high packet loss
      # Application decides to reduce MTU
      event = %MTUUpdateEvent{mtu: 1200}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 1200

      # Further reduction if loss continues
      event = %MTUUpdateEvent{mtu: 800}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 800
    end

    test "stable transmission scenario: increase MTU" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 800})
      assert state.mtu == 800

      # Simulate stable transmission, try larger MTU
      event = %MTUUpdateEvent{mtu: 1200}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 1200

      # Still stable, increase further
      event = %MTUUpdateEvent{mtu: 1500}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 1500
    end

    test "path MTU discovery scenario" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1200})

      # Path MTU discovery finds smaller supported MTU
      event = %MTUUpdateEvent{mtu: 1280}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 1280
    end

    test "local network jumbo frames scenario" do
      {_actions, state} = Payloader.handle_init(nil, %{mtu: 1500})

      # Detect local network, enable jumbo frames
      event = %MTUUpdateEvent{mtu: 9000}
      {_actions, state} = Payloader.handle_event(:input, event, nil, state)
      assert state.mtu == 9000
    end
  end

  describe "MTU edge cases" do
    test "minimum MTU (64) still produces valid packets" do
      # Very small OBU
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      access_unit = IO.iodata_to_binary([obu])

      {_actions, state} = Payloader.handle_init(nil, %{mtu: 64})
      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      packets =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should still produce packets
      assert length(packets) > 0

      # All packets should have marker bit on last packet
      last_packet = List.last(packets)
      assert last_packet.metadata.rtp.marker == true
    end

    test "MTU exactly at boundary values" do
      boundary_mtus = [64, 256, 512, 1200, 1500, 5000, 9000]

      Enum.each(boundary_mtus, fn mtu ->
        {_actions, state} = Payloader.handle_init(nil, %{mtu: mtu})
        assert state.mtu == mtu

        # Update to same MTU should work
        event = %MTUUpdateEvent{mtu: mtu}
        {_actions, state} = Payloader.handle_event(:input, event, nil, state)
        assert state.mtu == mtu
      end)
    end
  end
end
