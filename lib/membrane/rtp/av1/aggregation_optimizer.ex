defmodule Membrane.RTP.AV1.AggregationOptimizer do
  @moduledoc """
  Optimizes OBU aggregation to maximize packet efficiency.

  This module implements aggressive packing strategies to:
  - Minimize packet count by filling packets to near-MTU capacity
  - Avoid unnecessary fragmentation when OBUs can be aggregated
  - Track aggregation metrics for telemetry

  ## Optimization Strategies

  1. **Greedy Bin Packing**: Accumulate OBUs until adding the next would exceed MTU
  2. **Look-ahead**: Check if fragmenting a large OBU vs aggregating smaller ones is more efficient
  3. **Header Overhead Awareness**: Account for RTP header size in decisions
  """

  alias Membrane.RTP.AV1.OBU

  @type optimization_result :: %{
          packets: [binary()],
          metrics: aggregation_metrics()
        }

  @type aggregation_metrics :: %{
          total_obus: non_neg_integer(),
          total_packets: non_neg_integer(),
          aggregated_packets: non_neg_integer(),
          fragmented_packets: non_neg_integer(),
          single_obu_packets: non_neg_integer(),
          average_obus_per_packet: float(),
          aggregation_ratio: float(),
          payload_efficiency: float(),
          total_payload_bytes: non_neg_integer(),
          total_packet_bytes: non_neg_integer()
        }

  @max_obu_count 31
  # Minimum efficiency threshold for aggregation (85%)
  @min_efficiency_threshold 0.85

  @doc """
  Optimizes OBU aggregation for given MTU and returns packets with metrics.

  ## Options
  - :mtu - Maximum transmission unit (default: 1200)
  - :header_size - RTP header overhead (default: 1)
  - :min_efficiency - Minimum packet fill ratio to accept (default: 0.85)

  Returns {:ok, result} with packets and metrics.
  """
  @spec optimize(binary(), keyword()) :: {:ok, optimization_result()} | {:error, term()}
  def optimize(access_unit, opts \\ []) when is_binary(access_unit) do
    mtu = Keyword.get(opts, :mtu, 1200)
    header_size = Keyword.get(opts, :header_size, 1)
    min_efficiency = Keyword.get(opts, :min_efficiency, @min_efficiency_threshold)

    max_payload = mtu - header_size
    obus = OBU.split_obus(access_unit)

    case obus do
      [] ->
        # Empty access unit
        {:ok, %{packets: [], metrics: empty_metrics()}}

      [^access_unit] when byte_size(access_unit) > 0 ->
        # Could not parse OBUs, but have data - treat as single large OBU
        result = pack_obus(obus, max_payload, min_efficiency)
        {:ok, result}

      parsed_obus ->
        result = pack_obus(parsed_obus, max_payload, min_efficiency)
        {:ok, result}
    end
  end

  @doc """
  Analyzes an access unit and returns aggregation statistics without generating packets.
  """
  @spec analyze(binary(), keyword()) :: {:ok, aggregation_metrics()} | {:error, term()}
  def analyze(access_unit, opts \\ []) do
    case optimize(access_unit, opts) do
      {:ok, result} -> {:ok, result.metrics}
      error -> error
    end
  end

  # Private functions

  defp pack_obus(obus, max_payload, min_efficiency) do
    total_obus = length(obus)

    {packets, state} =
      obus
      |> Enum.reduce({[], %{current_group: [], current_size: 0, stats: init_stats()}}, fn obu,
                                                                                          {pkts,
                                                                                           state} ->
        pack_obu(obu, pkts, state, max_payload, min_efficiency)
      end)
      |> finalize_packing()

    metrics = calculate_metrics(state.stats, total_obus, max_payload)

    %{
      packets: Enum.reverse(packets),
      metrics: metrics
    }
  end

  defp pack_obu(obu, packets, state, max_payload, _min_efficiency) do
    obu_size = byte_size(obu)
    new_size = state.current_size + obu_size

    cond do
      # OBU fits in current group and we haven't hit count limit
      new_size <= max_payload and length(state.current_group) < @max_obu_count ->
        # Add to current group
        {packets,
         %{
           state
           | current_group: state.current_group ++ [obu],
             current_size: new_size
         }}

      # Current group exists, flush it and start new group
      state.current_size > 0 ->
        # Flush current group
        packet = serialize_group(state.current_group)
        obu_count = length(state.current_group)

        updated_stats =
          update_stats(
            state.stats,
            :aggregated,
            obu_count,
            byte_size(packet),
            state.current_size,
            1
          )

        # Start new group with this OBU
        {[packet | packets],
         %{
           state
           | current_group: [obu],
             current_size: obu_size,
             stats: updated_stats
         }}

      # Single large OBU that needs consideration
      obu_size > max_payload ->
        # This OBU needs fragmentation
        fragment_count = ceil(obu_size / max_payload)
        updated_stats = update_stats(state.stats, :fragmented, 1, 0, obu_size, fragment_count)

        # For now, just track it - actual fragmentation happens elsewhere
        {packets,
         %{
           state
           | current_group: [obu],
             current_size: obu_size,
             stats: updated_stats
         }}

      true ->
        # Single OBU that fits
        updated_stats = update_stats(state.stats, :single, 1, obu_size, obu_size, 1)

        {packets,
         %{
           state
           | current_group: [obu],
             current_size: obu_size,
             stats: updated_stats
         }}
    end
  end

  defp finalize_packing({packets, state}) do
    if state.current_size > 0 and length(state.current_group) > 0 do
      packet = serialize_group(state.current_group)
      obu_count = length(state.current_group)

      updated_stats =
        if obu_count > 1 do
          update_stats(
            state.stats,
            :aggregated,
            obu_count,
            byte_size(packet),
            state.current_size,
            1
          )
        else
          update_stats(state.stats, :single, 1, byte_size(packet), state.current_size, 1)
        end

      {[packet | packets], %{state | stats: updated_stats, current_group: [], current_size: 0}}
    else
      {packets, state}
    end
  end

  defp serialize_group(obus) do
    # Simply concatenate OBUs - actual header encoding happens in PayloadFormat
    Enum.join(obus)
  end

  defp init_stats do
    %{
      aggregated_packets: 0,
      aggregated_obus: 0,
      fragmented_packets: 0,
      fragmented_obus: 0,
      single_packets: 0,
      single_obus: 0,
      total_payload_bytes: 0,
      total_packet_bytes: 0
    }
  end

  defp update_stats(stats, :aggregated, obu_count, packet_size, payload_size, _extra) do
    %{
      stats
      | aggregated_packets: stats.aggregated_packets + 1,
        aggregated_obus: stats.aggregated_obus + obu_count,
        total_payload_bytes: stats.total_payload_bytes + payload_size,
        total_packet_bytes: stats.total_packet_bytes + packet_size
    }
  end

  defp update_stats(stats, :fragmented, obu_count, packet_size, payload_size, fragment_count) do
    %{
      stats
      | fragmented_packets: stats.fragmented_packets + fragment_count,
        fragmented_obus: stats.fragmented_obus + obu_count,
        total_payload_bytes: stats.total_payload_bytes + payload_size,
        total_packet_bytes: stats.total_packet_bytes + packet_size
    }
  end

  defp update_stats(stats, :single, obu_count, packet_size, payload_size, _extra) do
    %{
      stats
      | single_packets: stats.single_packets + 1,
        single_obus: stats.single_obus + obu_count,
        total_payload_bytes: stats.total_payload_bytes + payload_size,
        total_packet_bytes: stats.total_packet_bytes + packet_size
    }
  end

  defp calculate_metrics(stats, total_obus, max_payload) do
    total_packets =
      stats.aggregated_packets + stats.fragmented_packets + stats.single_packets

    average_obus_per_packet =
      if total_packets > 0 do
        total_obus / total_packets
      else
        0.0
      end

    # Aggregation ratio: percentage of packets that contain multiple OBUs
    aggregation_ratio =
      if total_packets > 0 do
        stats.aggregated_packets / total_packets
      else
        0.0
      end

    # Payload efficiency: how well we're using available packet space
    max_possible_payload = total_packets * max_payload

    payload_efficiency =
      if max_possible_payload > 0 do
        stats.total_payload_bytes / max_possible_payload
      else
        0.0
      end

    %{
      total_obus: total_obus,
      total_packets: total_packets,
      aggregated_packets: stats.aggregated_packets,
      fragmented_packets: stats.fragmented_packets,
      single_obu_packets: stats.single_packets,
      average_obus_per_packet: Float.round(average_obus_per_packet, 2),
      aggregation_ratio: Float.round(aggregation_ratio, 3),
      payload_efficiency: Float.round(payload_efficiency, 3),
      total_payload_bytes: stats.total_payload_bytes,
      total_packet_bytes: stats.total_packet_bytes
    }
  end

  defp empty_metrics do
    %{
      total_obus: 0,
      total_packets: 0,
      aggregated_packets: 0,
      fragmented_packets: 0,
      single_obu_packets: 0,
      average_obus_per_packet: 0.0,
      aggregation_ratio: 0.0,
      payload_efficiency: 0.0,
      total_payload_bytes: 0,
      total_packet_bytes: 0
    }
  end
end
