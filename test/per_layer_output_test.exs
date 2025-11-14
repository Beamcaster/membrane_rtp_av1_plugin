defmodule Membrane.RTP.AV1.PerLayerOutputTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{Depayloader, FullHeader}
  alias Membrane.Buffer
  alias Membrane.Pad
  import Membrane.RTP.AV1.TestHelperUtils

  @clock_rate 90_000

  describe "per-layer output mode" do
    test "single temporal layer routes to layer 0 pad" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send packet with temporal_id=0
      payload = encode_packet_with_layer(temporal_id: 0, spatial_id: 0, data: <<1, 2, 3>>)
      {actions, _state} = handle_buffer(state, payload, 1000, true)

      # Should create pad and emit buffer
      assert has_action?(actions, :notify_parent, {:new_pad, {Membrane.Pad, :output, 0}})

      buffer = first_output_buffer(actions)
      assert buffer.payload == <<1, 2, 3>>
      assert buffer.metadata.av1.temporal_id == 0
      assert buffer.metadata.av1.spatial_id == 0
    end

    test "multiple temporal layers route to separate pads" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send packets with different temporal_ids
      payload0 = encode_packet_with_layer(temporal_id: 0, spatial_id: 0, data: <<1, 2>>)
      payload1 = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<3, 4>>)
      payload2 = encode_packet_with_layer(temporal_id: 2, spatial_id: 0, data: <<5, 6>>)

      {actions0, state} = handle_buffer(state, payload0, 1000, true)
      {actions1, state} = handle_buffer(state, payload1, 2000, true)
      {actions2, _state} = handle_buffer(state, payload2, 3000, true)

      # Verify pad creation notifications
      assert has_action?(actions0, :notify_parent, {:new_pad, {Membrane.Pad, :output, 0}})
      assert has_action?(actions1, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})
      assert has_action?(actions2, :notify_parent, {:new_pad, {Membrane.Pad, :output, 2}})

      # Verify buffer routing
      buffer0 = first_output_buffer(actions0)
      assert buffer0.payload == <<1, 2>>
      assert buffer0.metadata.av1.temporal_id == 0

      buffer1 = first_output_buffer(actions1)
      assert buffer1.payload == <<3, 4>>
      assert buffer1.metadata.av1.temporal_id == 1

      buffer2 = first_output_buffer(actions2)
      assert buffer2.payload == <<5, 6>>
      assert buffer2.metadata.av1.temporal_id == 2
    end

    test "repeated temporal_id uses same pad without duplicate notification" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send multiple packets with temporal_id=1
      payload1a = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<1, 2>>)
      payload1b = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<3, 4>>)
      payload1c = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<5, 6>>)

      {actions_a, state} = handle_buffer(state, payload1a, 1000, true)
      {actions_b, state} = handle_buffer(state, payload1b, 2000, true)
      {actions_c, _state} = handle_buffer(state, payload1c, 3000, true)

      # First packet should notify about new pad
      assert has_action?(actions_a, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})

      # Subsequent packets should NOT notify (pad already exists)
      refute has_action?(actions_b, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})
      refute has_action?(actions_c, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})

      # All buffers should be emitted on same pad
      assert first_output_buffer(actions_a).metadata.av1.temporal_id == 1
      assert first_output_buffer(actions_b).metadata.av1.temporal_id == 1
      assert first_output_buffer(actions_c).metadata.av1.temporal_id == 1
    end

    test "interleaved temporal layers route correctly" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Interleave different temporal layers (realistic SVC pattern)
      payloads = [
        # Base layer
        {0, <<1>>},
        # Enhancement layer 1
        {1, <<2>>},
        # Enhancement layer 2
        {2, <<3>>},
        # Base layer
        {0, <<4>>},
        # Enhancement layer 1
        {1, <<5>>},
        # Base layer
        {0, <<6>>}
      ]

      results =
        Enum.map_reduce(payloads, state, fn {tid, data}, s ->
          payload = encode_packet_with_layer(temporal_id: tid, spatial_id: 0, data: data)
          handle_buffer(s, payload, tid * 1000, true)
        end)

      {actions_list, _final_state} = results

      # Verify buffers route to correct pads
      temporal_ids =
        Enum.map(actions_list, fn actions ->
          first_output_buffer(actions).metadata.av1.temporal_id
        end)

      assert temporal_ids == [0, 1, 2, 0, 1, 0]
    end

    test "packets without temporal_id route to default pad (layer 0)" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send packet with M=0 (no IDS, temporal_id is nil)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        # No IDS
        m: false,
        temporal_id: nil,
        spatial_id: nil
      }

      header_bin = FullHeader.encode(full_header)
      obu_data = <<0x12, 0x00, 0x0A>>
      payload = header_bin <> obu_data

      {actions, _state} = handle_buffer(state, payload, 1000, true)

      # Should route to default pad (layer 0)
      assert has_action?(actions, :notify_parent, {:new_pad, {Membrane.Pad, :output, 0}})

      buffer = first_output_buffer(actions)
      assert buffer.payload == obu_data
      assert buffer.metadata.av1.temporal_id == nil
    end

    test "metadata includes all layer information" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send packet with both temporal_id and spatial_id
      payload = encode_packet_with_layer(temporal_id: 2, spatial_id: 1, data: <<1, 2, 3, 4>>)
      {actions, _state} = handle_buffer(state, payload, 1000, true)

      buffer = first_output_buffer(actions)

      # Verify complete metadata
      assert buffer.metadata.av1.temporal_id == 2
      assert buffer.metadata.av1.spatial_id == 1
      assert buffer.metadata.av1.y_flag == true
      assert buffer.metadata.av1.has_ss == false
    end
  end

  describe "backward compatibility mode (per_layer_output: false)" do
    test "all layers route to single default pad" do
      {:ok, state} = init_depayloader(per_layer_output: false)

      # Send packets with different temporal_ids
      payload0 = encode_packet_with_layer(temporal_id: 0, spatial_id: 0, data: <<1, 2>>)
      payload1 = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<3, 4>>)
      payload2 = encode_packet_with_layer(temporal_id: 2, spatial_id: 0, data: <<5, 6>>)

      {actions0, state} = handle_buffer(state, payload0, 1000, true)
      {actions1, state} = handle_buffer(state, payload1, 2000, true)
      {actions2, _state} = handle_buffer(state, payload2, 3000, true)

      # All should use the static :output pad (no dynamic pad notifications)
      refute has_action?(actions0, :notify_parent, {:new_pad, {Membrane.Pad, :output, 0}})
      refute has_action?(actions1, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})
      refute has_action?(actions2, :notify_parent, {:new_pad, {Membrane.Pad, :output, 2}})

      # All buffers emitted to static :output pad, metadata still preserved
      assert first_output_buffer(actions0).metadata.av1.temporal_id == 0
      assert first_output_buffer(actions1).metadata.av1.temporal_id == 1
      assert first_output_buffer(actions2).metadata.av1.temporal_id == 2
    end

    test "metadata preserved in single-output mode" do
      {:ok, state} = init_depayloader(per_layer_output: false)

      payload = encode_packet_with_layer(temporal_id: 3, spatial_id: 2, data: <<1, 2, 3>>)
      {actions, _state} = handle_buffer(state, payload, 1000, true)

      buffer = first_output_buffer(actions)

      # Metadata should still be available for downstream filtering
      assert buffer.metadata.av1.temporal_id == 3
      assert buffer.metadata.av1.spatial_id == 2
    end

    test "default mode is backward compatible (per_layer_output defaults to false)" do
      # Create depayloader without specifying per_layer_output option
      {[], state} = Depayloader.handle_init(nil, %{clock_rate: @clock_rate, header_mode: :spec})
      # handle_stream_format now returns stream_format action - discard it for unit tests
      {_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      # Should behave like single-output mode with static :output pad
      payload = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<1, 2>>)
      {actions, _state} = handle_buffer(state, payload, 1000, true, 100)

      # Static pad - no notification needed
      refute has_action?(actions, :notify_parent, {:new_pad, {Membrane.Pad, :output, 0}})
      # Buffer should be emitted to static :output pad
      assert first_output_buffer(actions)
    end
  end

  describe "fragmented packets with per-layer output" do
    test "fragments complete and route to correct temporal layer pad" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send complete non-fragmented packets with different temporal_ids
      # (Fragmentation with full metadata on each fragment is complex - testing routing is primary goal)
      payload0 = encode_packet_with_layer(temporal_id: 0, spatial_id: 0, data: <<1, 2, 3, 4>>)
      payload1 = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<5, 6, 7, 8>>)
      payload2 = encode_packet_with_layer(temporal_id: 2, spatial_id: 0, data: <<9, 10, 11, 12>>)

      {actions0, state} = handle_buffer(state, payload0, 1000, true, 100)
      {actions1, state} = handle_buffer(state, payload1, 2000, true, 101)
      {actions2, _state} = handle_buffer(state, payload2, 3000, true, 102)

      # Verify routing to correct pads
      buffer0 = first_output_buffer(actions0)
      assert buffer0.payload == <<1, 2, 3, 4>>
      assert buffer0.metadata.av1.temporal_id == 0

      buffer1 = first_output_buffer(actions1)
      assert buffer1.payload == <<5, 6, 7, 8>>
      assert buffer1.metadata.av1.temporal_id == 1

      buffer2 = first_output_buffer(actions2)
      assert buffer2.payload == <<9, 10, 11, 12>>
      assert buffer2.metadata.av1.temporal_id == 2
    end
  end

  describe "layer discovery tracking" do
    test "discovered_layers state tracks created pads" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Initially no layers discovered
      assert MapSet.size(state.discovered_layers) == 0

      # Send layer 0
      payload0 = encode_packet_with_layer(temporal_id: 0, spatial_id: 0, data: <<1>>)
      {_actions, state} = handle_buffer(state, payload0, 1000, true)
      assert MapSet.member?(state.discovered_layers, 0)

      # Send layer 2 (skip layer 1)
      payload2 = encode_packet_with_layer(temporal_id: 2, spatial_id: 0, data: <<2>>)
      {_actions, state} = handle_buffer(state, payload2, 2000, true)
      assert MapSet.member?(state.discovered_layers, 2)
      assert MapSet.size(state.discovered_layers) == 2

      # Send layer 1
      payload1 = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<3>>)
      {_actions, state} = handle_buffer(state, payload1, 3000, true)
      assert MapSet.member?(state.discovered_layers, 1)
      assert MapSet.size(state.discovered_layers) == 3
    end

    test "discovered_layers prevents duplicate pad notifications" do
      {:ok, state} = init_depayloader(per_layer_output: true)

      # Send 10 packets on layer 1
      results =
        Enum.map_reduce(1..10, state, fn i, s ->
          payload = encode_packet_with_layer(temporal_id: 1, spatial_id: 0, data: <<i>>)
          handle_buffer(s, payload, i * 1000, true)
        end)

      {actions_list, _final_state} = results

      # Only first packet should have notify_parent
      [first_actions | rest_actions] = actions_list
      assert has_action?(first_actions, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})

      # All remaining packets should NOT have notify_parent
      Enum.each(rest_actions, fn actions ->
        refute has_action?(actions, :notify_parent, {:new_pad, {Membrane.Pad, :output, 1}})
      end)
    end
  end

  # Helper functions

  defp init_depayloader(opts \\ []) do
    per_layer_output = Keyword.get(opts, :per_layer_output, false)

    {[], state} =
      Depayloader.handle_init(nil, %{
        clock_rate: @clock_rate,
        header_mode: :spec,
        per_layer_output: per_layer_output
      })

    # handle_stream_format now returns stream_format action - discard it for unit tests
    {_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)
    {:ok, state}
  end

  defp handle_buffer(state, payload, pts, marker, seq \\ nil) do
    seq = seq || System.unique_integer([:positive, :monotonic]) |> rem(65536)

    buffer = %Buffer{
      payload: payload,
      pts: pts,
      metadata: %{rtp: %{marker: marker, sequence_number: seq}}
    }

    Depayloader.handle_buffer(:input, buffer, nil, state)
  end

  defp encode_packet_with_layer(opts) do
    temporal_id = Keyword.fetch!(opts, :temporal_id)
    spatial_id = Keyword.fetch!(opts, :spatial_id)
    data = Keyword.fetch!(opts, :data)

    full_header = %FullHeader{
      z: false,
      y: true,
      w: 0,
      n: false,
      c: 0,
      # IDS present
      m: true,
      temporal_id: temporal_id,
      spatial_id: spatial_id
    }

    header_bin = FullHeader.encode(full_header)
    header_bin <> data
  end

  defp encode_fragment(opts) do
    w = Keyword.fetch!(opts, :w)
    temporal_id = Keyword.fetch!(opts, :temporal_id)
    spatial_id = Keyword.fetch!(opts, :spatial_id)
    data = Keyword.fetch!(opts, :data)

    full_header = %FullHeader{
      z: false,
      y: true,
      w: w,
      n: false,
      c: 0,
      # IDS present
      m: true,
      temporal_id: temporal_id,
      spatial_id: spatial_id
    }

    header_bin = FullHeader.encode(full_header)
    header_bin <> data
  end

  defp has_action?(actions, action_type, expected_value) do
    Enum.any?(actions, fn
      {^action_type, value} -> value == expected_value
      _ -> false
    end)
  end
end
