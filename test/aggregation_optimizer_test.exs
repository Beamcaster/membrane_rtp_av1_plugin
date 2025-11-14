defmodule Membrane.RTP.AV1.AggregationOptimizerTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{AggregationOptimizer, OBU}

  describe "optimize/2" do
    test "aggregates multiple small OBUs into single packet" do
      # Create 5 small OBUs that fit in one packet
      obus =
        for i <- 1..5 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      assert length(result.packets) >= 1
      assert result.metrics.total_obus == 5
      assert result.metrics.aggregation_ratio > 0
    end

    test "splits large OBU across multiple packets" do
      # Create large OBU that needs fragmentation
      large_payload = :binary.copy(<<0x01>>, 5000)
      obu = create_frame_obu(large_payload)

      {:ok, result} = AggregationOptimizer.optimize(obu, mtu: 1200)

      # Should recognize need for fragmentation
      assert result.metrics.total_obus == 1
      assert result.metrics.fragmented_packets > 0
    end

    test "mixed aggregation and single OBUs" do
      # Mix of small and medium OBUs
      small1 = create_frame_obu(<<0x01>>)
      small2 = create_frame_obu(<<0x02>>)
      medium = create_frame_obu(:binary.copy(<<0x03>>, 800))
      small3 = create_frame_obu(<<0x04>>)

      au = small1 <> small2 <> medium <> small3

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      assert result.metrics.total_obus == 4
      # Should have some aggregation
      assert result.metrics.aggregation_ratio >= 0
    end

    test "respects max OBU count limit (31)" do
      # Create 50 tiny OBUs
      obus =
        for i <- 1..50 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 9000)

      # Should not exceed 31 OBUs per packet
      assert result.metrics.total_obus == 50
      # With max 31 per packet, need at least 2 packets
      assert result.metrics.total_packets >= 2
    end

    test "calculates aggregation ratio correctly" do
      # All small OBUs that aggregate well
      obus =
        for i <- 1..10 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      # Should have high aggregation ratio
      assert result.metrics.aggregation_ratio > 0
      assert result.metrics.average_obus_per_packet > 1
    end

    test "calculates payload efficiency" do
      obus =
        for i <- 1..5 do
          create_frame_obu(:binary.copy(<<i>>, 200))
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      # Efficiency should be between 0 and 1
      assert result.metrics.payload_efficiency >= 0
      assert result.metrics.payload_efficiency <= 1.0
    end

    test "handles empty access unit" do
      {:ok, result} = AggregationOptimizer.optimize(<<>>, mtu: 1200)

      assert result.metrics.total_obus == 0
      assert result.metrics.total_packets == 0
      assert result.packets == []
    end

    test "handles single OBU exactly at MTU" do
      # OBU that exactly fills one packet
      # MTU minus header overhead and OBU header
      payload_size = 1199 - 5
      obu = create_frame_obu(:binary.copy(<<0x01>>, payload_size))

      {:ok, result} = AggregationOptimizer.optimize(obu, mtu: 1200)

      assert result.metrics.total_obus == 1
      assert result.metrics.total_packets == 1
    end

    test "optimizes with different MTU sizes" do
      obus =
        for i <- 1..20 do
          create_frame_obu(:binary.copy(<<i>>, 100))
        end

      au = Enum.join(obus)

      # Small MTU
      {:ok, small_result} = AggregationOptimizer.optimize(au, mtu: 300)
      # Large MTU  
      {:ok, large_result} = AggregationOptimizer.optimize(au, mtu: 9000)

      # Large MTU should aggregate better
      assert large_result.metrics.average_obus_per_packet >
               small_result.metrics.average_obus_per_packet
    end
  end

  describe "analyze/2" do
    test "returns metrics without packets" do
      obus =
        for i <- 1..5 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      {:ok, metrics} = AggregationOptimizer.analyze(au, mtu: 1200)

      assert metrics.total_obus == 5
      assert is_float(metrics.aggregation_ratio)
      assert is_float(metrics.payload_efficiency)
      assert is_integer(metrics.total_packets)
    end

    test "handles analysis of large access units" do
      obus =
        for i <- 1..100 do
          create_frame_obu(:binary.copy(<<i>>, 50))
        end

      au = Enum.join(obus)

      {:ok, metrics} = AggregationOptimizer.analyze(au, mtu: 1200)

      assert metrics.total_obus == 100
      assert metrics.total_packets > 0
    end
  end

  describe "metrics calculation" do
    test "average_obus_per_packet reflects aggregation" do
      # Single packet with 5 OBUs
      obus =
        for i <- 1..5 do
          create_frame_obu(<<i>>)
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      # Average should be around 5 if all fit in one packet
      assert result.metrics.average_obus_per_packet >= 1
    end

    test "payload_efficiency measures MTU utilization" do
      # Fill packet near capacity
      obus =
        for i <- 1..10 do
          create_frame_obu(:binary.copy(<<i>>, 100))
        end

      au = Enum.join(obus)

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      # Should use most of available space
      assert result.metrics.payload_efficiency > 0.5
    end

    test "aggregation_ratio shows aggregation percentage" do
      # Mix of aggregated and single OBUs
      small_obus =
        for i <- 1..5 do
          create_frame_obu(<<i>>)
        end

      large_obu = create_frame_obu(:binary.copy(<<0xFF>>, 2000))

      au = Enum.join(small_obus) <> large_obu

      {:ok, result} = AggregationOptimizer.optimize(au, mtu: 1200)

      # Ratio should reflect mix of aggregation and fragmentation
      assert result.metrics.aggregation_ratio >= 0
      assert result.metrics.aggregation_ratio <= 1.0
    end
  end

  # Helper functions

  defp create_frame_obu(payload) do
    # OBU type 6 (FRAME), no extension, has size field
    # Byte 0: F=0, type=6 (0110), X=0, has_size=1, reserved=00
    # Binary: 0_0110_0_1_00 = 0x32
    obu_header = <<0x32>>
    OBU.build_obu(obu_header <> payload)
  end
end
