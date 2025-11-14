defmodule Membrane.RTP.AV1.LayerFilteringTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.Buffer
  alias Membrane.RTP.AV1.FullHeader
  import Membrane.RTP.AV1.TestHelperUtils

  # Set up telemetry handler for each test
  setup do
    test_pid = self()

    :telemetry.attach_many(
      "test-layer-filtering-#{:erlang.unique_integer()}",
      [
        [:membrane_rtp_av1, :depayloader, :layer_filtered]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-layer-filtering-#{:erlang.unique_integer()}")
    end)

    :ok
  end

  describe "temporal_id filtering" do
    test "filters packets with temporal_id exceeding max_temporal_id" do
      # Initialize depayloader with max_temporal_id=2
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: nil
        })

      # Create packet with temporal_id=3 (exceeds threshold)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should return no actions (packet filtered)
      assert actions == []

      # Should emit telemetry event
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered],
                       %{count: 1},
                       %{
                         temporal_id: 3,
                         spatial_id: 0,
                         max_temporal_id: 2,
                         max_spatial_id: nil,
                         reason: :temporal_layer_exceeds_threshold
                       }}
    end

    test "passes packets with temporal_id within threshold" do
      # Initialize depayloader with max_temporal_id=2
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: nil
        })

      # Create packet with temporal_id=1 (within threshold)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 1,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (packet passed)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end

    test "passes packets with temporal_id equal to max_temporal_id" do
      # Initialize depayloader with max_temporal_id=2
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: nil
        })

      # Create packet with temporal_id=2 (equal to threshold)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 2,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (packet passed)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end
  end

  describe "spatial_id filtering" do
    test "filters packets with spatial_id exceeding max_spatial_id" do
      # Initialize depayloader with max_spatial_id=1
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: nil,
          max_spatial_id: 1
        })

      # Create packet with spatial_id=2 (exceeds threshold)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 2
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should return no actions (packet filtered)
      assert actions == []

      # Should emit telemetry event
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered],
                       %{count: 1},
                       %{
                         temporal_id: 0,
                         spatial_id: 2,
                         max_temporal_id: nil,
                         max_spatial_id: 1,
                         reason: :spatial_layer_exceeds_threshold
                       }}
    end

    test "passes packets with spatial_id within threshold" do
      # Initialize depayloader with max_spatial_id=1
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: nil,
          max_spatial_id: 1
        })

      # Create packet with spatial_id=0 (within threshold)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 0,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (packet passed)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end
  end

  describe "combined temporal_id and spatial_id filtering" do
    test "filters packets exceeding both thresholds" do
      # Initialize depayloader with both filters
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: 1
        })

      # Create packet with temporal_id=3, spatial_id=2 (both exceed)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        spatial_id: 2
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should return no actions (packet filtered)
      assert actions == []

      # Should emit telemetry event with both_layers_exceed_threshold reason
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered],
                       %{count: 1},
                       %{
                         temporal_id: 3,
                         spatial_id: 2,
                         max_temporal_id: 2,
                         max_spatial_id: 1,
                         reason: :both_layers_exceed_threshold
                       }}
    end

    test "filters packets exceeding only temporal_id" do
      # Initialize depayloader with both filters
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: 1
        })

      # Create packet with temporal_id=3 (exceeds), spatial_id=0 (within)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 3,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should return no actions (packet filtered)
      assert actions == []

      # Should emit telemetry event with temporal_layer_exceeds_threshold reason
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered],
                       %{count: 1},
                       %{
                         temporal_id: 3,
                         spatial_id: 0,
                         max_temporal_id: 2,
                         max_spatial_id: 1,
                         reason: :temporal_layer_exceeds_threshold
                       }}
    end

    test "passes packets within both thresholds" do
      # Initialize depayloader with both filters
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: 1
        })

      # Create packet with temporal_id=1, spatial_id=0 (both within)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 1,
        spatial_id: 0
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (packet passed)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end
  end

  describe "no filtering (default behavior)" do
    test "passes all packets when both filters are nil" do
      # Initialize depayloader with no filtering (defaults)
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: nil,
          max_spatial_id: nil
        })

      # Create packet with high temporal_id and spatial_id
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 7,
        spatial_id: 3
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (no filtering)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end

    test "passes packets without M flag (no IDS present)" do
      # Initialize depayloader with filtering enabled
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 2,
          max_spatial_id: 1
        })

      # Create packet without M flag (no temporal_id/spatial_id)
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        temporal_id: nil,
        spatial_id: nil
      }

      header_bin = FullHeader.encode(full_header)
      payload = header_bin <> <<1, 2, 3, 4>>

      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      # Process packet
      {actions, _new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output buffer (packet has no IDS, so filtering doesn't apply)
      assert has_buffer_output?(actions)

      # Should NOT emit filter telemetry event
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end
  end

  describe "multiple filtered packets" do
    test "emits telemetry event for each filtered packet" do
      # Initialize depayloader with max_temporal_id=1
      {[], state} =
        Depayloader.handle_init(nil, %{
          clock_rate: 90_000,
          fmtp: %{},
          header_mode: :spec,
          max_temporal_id: 1,
          max_spatial_id: nil
        })

      # Create and process 3 packets with temporal_id=2 (all filtered)
      for seq <- 100..102 do
        full_header = %FullHeader{
          z: false,
          y: true,
          w: 0,
          n: false,
          c: 0,
          m: true,
          temporal_id: 2,
          spatial_id: 0
        }

        header_bin = FullHeader.encode(full_header)
        payload = header_bin <> <<1, 2, 3, 4>>

        buffer = %Buffer{
          payload: payload,
          pts: seq * 1000,
          metadata: %{rtp: %{marker: true, sequence_number: seq}}
        }

        {actions, new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)
        assert actions == []
        state = new_state
      end

      # Should emit 3 telemetry events
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
      assert_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
      refute_received {:telemetry, [:membrane_rtp_av1, :depayloader, :layer_filtered], _, _}
    end
  end
end
