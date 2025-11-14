defmodule Membrane.RTP.AV1.AggregationTelemetryTest do
  use ExUnit.Case, async: false

  alias Membrane.RTP.AV1.{PayloadFormat, OBU}

  setup do
    # Attach telemetry handler
    test_pid = self()
    handler_id = "test-aggregation-telemetry-#{:erlang.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:membrane_rtp_av1, :aggregation, :complete],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  describe "aggregation telemetry" do
    test "emits telemetry on successful fragmentation" do
      # Create multiple small OBUs
      obus =
        for i <- 1..5 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      _packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      # Should receive telemetry event
      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements,
                      metadata},
                     1000

      # Verify measurements
      assert measurements.total_obus == 5
      assert measurements.total_packets >= 1
      assert is_float(measurements.aggregation_ratio)
      assert is_float(measurements.payload_efficiency)
      assert is_float(measurements.average_obus_per_packet)
      assert is_integer(measurements.aggregated_packets)

      # Verify metadata
      assert is_integer(metadata.mtu)
    end

    test "emits metrics for fragmented OBUs" do
      # Create multiple OBUs where one is large enough to need fragmentation
      small_obus =
        for i <- 1..2 do
          create_frame_obu(<<i>>)
        end

      # This OBU is large but still parseable
      large_obu = create_frame_obu(:binary.copy(<<0xFF>>, 2000))

      au = Enum.join(small_obus) <> large_obu

      _packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      assert measurements.total_obus == 3
      # Should have multiple packets due to large OBU
      assert measurements.total_packets > 1
    end

    test "emits metrics for mixed aggregation and fragmentation" do
      # Mix of small OBUs and one large
      small_obus =
        for i <- 1..3 do
          create_frame_obu(<<i>>)
        end

      large_obu = create_frame_obu(:binary.copy(<<0xFF>>, 2000))

      au = Enum.join(small_obus) <> large_obu

      _packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      assert measurements.total_obus == 4
      assert measurements.aggregation_ratio >= 0
      assert measurements.aggregation_ratio <= 1.0
    end

    test "emits telemetry with correct MTU metadata" do
      obus =
        for i <- 1..3 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      custom_mtu = 800
      _packets = PayloadFormat.fragment(au, mtu: custom_mtu, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], _, metadata},
                     1000

      # MTU in metadata should match max_payload (mtu - header_size)
      assert metadata.mtu == custom_mtu - 1
    end

    test "reports high aggregation ratio for many small OBUs" do
      # Many tiny OBUs that should aggregate well
      obus =
        for i <- 1..20 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      _packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      # Should have good aggregation
      assert measurements.average_obus_per_packet > 1
      assert measurements.aggregation_ratio > 0
    end

    test "reports payload efficiency" do
      # OBUs that fill packets well
      obus =
        for i <- 1..10 do
          create_frame_obu(:binary.copy(<<i>>, 100))
        end

      au = Enum.join(obus)

      _packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      # Efficiency should be reasonable (>50%)
      assert measurements.payload_efficiency > 0.5
      assert measurements.payload_efficiency <= 1.0
    end

    test "handles very small MTU" do
      # Multiple small OBUs with small MTU
      obus =
        for i <- 1..3 do
          create_frame_obu(:binary.copy(<<i>>, 50))
        end

      au = Enum.join(obus)

      _packets = PayloadFormat.fragment(au, mtu: 64, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      assert measurements.total_obus == 3
      # With small MTU, should need multiple packets
      assert measurements.total_packets > 1
    end

    test "handles jumbo frames" do
      obus =
        for i <- 1..50 do
          create_frame_obu(:binary.copy(<<i>>, 100))
        end

      au = Enum.join(obus)

      _packets = PayloadFormat.fragment(au, mtu: 9000, header_mode: :draft)

      assert_receive {:telemetry, [:membrane_rtp_av1, :aggregation, :complete], measurements, _},
                     1000

      # With large MTU, should aggregate very well
      assert measurements.average_obus_per_packet > 10
    end
  end

  # Helper functions

  defp create_frame_obu(payload) do
    # OBU type 6 (FRAME)
    obu_header = <<0x32>>
    OBU.build_obu(obu_header <> payload)
  end
end
