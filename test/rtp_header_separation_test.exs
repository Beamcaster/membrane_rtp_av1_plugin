defmodule Membrane.RTP.AV1.RTPHeaderSeparationTest do
  @moduledoc """
  Tests to verify RTP header separation between AV1 payloader/depayloader
  and the RTP layer (muxer/demuxer).

  This validates that:
  - Payloader outputs only payload data with marker bit in metadata
  - Depayloader receives RTP metadata (marker, sequence_number, timestamp)
  - RTP layer handles sequence numbers and timestamps
  - Integration works correctly end-to-end
  """
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.{Payloader, Depayloader, OBU}

  describe "payloader outputs payload with metadata" do
    test "marker bit is set in buffer metadata for last packet" do
      # Create a small access unit that fits in one packet
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      access_unit = IO.iodata_to_binary([obu])

      {_actions, state} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should have one packet with marker bit set
      assert length(buffers) == 1
      assert [buffer] = buffers
      assert buffer.metadata.rtp.marker == true
    end

    test "marker bit is only set on last packet for fragmented access unit" do
      # Create a large access unit that requires fragmentation
      large_obu = OBU.build_obu(:crypto.strong_rand_bytes(5_000))
      access_unit = IO.iodata_to_binary([large_obu])

      {_actions, state} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should have multiple packets
      assert length(buffers) > 1

      # All packets except last should have marker=false
      {init_packets, [last_packet]} = Enum.split(buffers, -1)

      Enum.each(init_packets, fn buffer ->
        assert buffer.metadata.rtp.marker == false,
               "Non-last packet should have marker=false"
      end)

      # Last packet should have marker=true
      assert last_packet.metadata.rtp.marker == true,
             "Last packet should have marker=true"
    end

    test "multiple access units have marker bit on each last packet" do
      # Create multiple small access units
      obu1 = OBU.build_obu(:crypto.strong_rand_bytes(100))
      obu2 = OBU.build_obu(:crypto.strong_rand_bytes(150))
      obu3 = OBU.build_obu(:crypto.strong_rand_bytes(200))

      access_units = [
        IO.iodata_to_binary([obu1]),
        IO.iodata_to_binary([obu2]),
        IO.iodata_to_binary([obu3])
      ]

      {_actions, state} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {all_buffers, _state} =
        Enum.reduce(access_units, {[], state}, fn au, {acc, st} ->
          {actions, new_state} =
            Payloader.handle_buffer(:input, %Buffer{payload: au, pts: 1_000_000}, nil, st)

          buffers =
            actions
            |> Enum.flat_map(fn
              {:buffer, {_pad_ref, buffer}} -> [buffer]
              _ -> []
            end)

          {acc ++ buffers, new_state}
        end)

      # Should have 3 packets (one per AU), all with marker=true
      assert length(all_buffers) == 3

      Enum.each(all_buffers, fn buffer ->
        assert buffer.metadata.rtp.marker == true,
               "Each access unit's packet should have marker=true"
      end)
    end

    test "payloader does not set sequence numbers or timestamps" do
      # These should be handled by the RTP layer (muxer)
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      access_unit = IO.iodata_to_binary([obu])

      {_actions, state} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, state} = Payloader.handle_stream_format(:input, :any, nil, state)

      {actions, _state} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: 1_000_000}, nil, state)

      buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      assert [buffer] = buffers

      # Verify payloader doesn't set sequence_number or timestamp
      # (these are added by RTP muxer)
      refute Map.has_key?(buffer.metadata.rtp, :sequence_number),
             "Payloader should not set sequence_number"

      refute Map.has_key?(buffer.metadata.rtp, :timestamp),
             "Payloader should not set timestamp"
    end
  end

  describe "depayloader receives RTP metadata" do
    test "depayloader reads marker bit from metadata" do
      # Create a properly formatted AV1 RTP payload (draft header + OBU)
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      # Draft header: S=1, E=1, F=0, C=0 (complete OBU)
      draft_header = <<0b11000000>>
      payload = draft_header <> obu

      buffer = %Buffer{
        payload: payload,
        pts: 1_000_000,
        metadata: %{rtp: %{marker: true, sequence_number: 100}}
      }

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})

      {_sf_actions, state} =
        Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, state)

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output an access unit
      output_buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      assert length(output_buffers) == 1
    end

    test "depayloader tracks sequence numbers from metadata" do
      # Create properly formatted AV1 RTP payloads
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      draft_header = <<0b11000000>>
      payload = draft_header <> obu

      packets = [
        %Buffer{
          payload: payload,
          pts: 1_000_000,
          metadata: %{rtp: %{marker: true, sequence_number: 100}}
        },
        %Buffer{
          payload: payload,
          pts: 2_000_000,
          metadata: %{rtp: %{marker: true, sequence_number: 101}}
        },
        %Buffer{
          payload: payload,
          pts: 3_000_000,
          metadata: %{rtp: %{marker: true, sequence_number: 102}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})

      {_sf_actions, state} =
        Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, state)

      {all_outputs, _state} =
        Enum.reduce(packets, {[], state}, fn packet, {acc, st} ->
          {actions, new_state} = Depayloader.handle_buffer(:input, packet, nil, st)

          outputs =
            actions
            |> Enum.flat_map(fn
              {:buffer, {_pad_ref, buffer}} -> [buffer]
              _ -> []
            end)

          {acc ++ outputs, new_state}
        end)

      # Should output 3 access units
      assert length(all_outputs) == 3
    end

    test "depayloader handles packets without sequence numbers gracefully" do
      # Some test scenarios might not include sequence numbers
      obu = OBU.build_obu(:crypto.strong_rand_bytes(100))
      draft_header = <<0b11000000>>
      payload = draft_header <> obu

      buffer = %Buffer{
        payload: payload,
        pts: 1_000_000,
        metadata: %{rtp: %{marker: true}}
      }

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})

      {_sf_actions, state} =
        Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, state)

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should still work without sequence numbers
      output_buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      assert length(output_buffers) == 1
    end
  end

  describe "integration validation" do
    test "RTP metadata flows correctly through payloader and depayloader" do
      # Create an access unit
      obu = OBU.build_obu(:crypto.strong_rand_bytes(500))
      access_unit = IO.iodata_to_binary([obu])
      pts = 5_000_000

      # Payloader
      {_actions, pstate} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, pstate} = Payloader.handle_stream_format(:input, :any, nil, pstate)

      {actions, _pstate} =
        Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: pts}, nil, pstate)

      # Get payloader outputs
      payloader_buffers =
        actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Verify payloader outputs have marker bit
      assert length(payloader_buffers) > 0
      last_buffer = List.last(payloader_buffers)
      assert last_buffer.metadata.rtp.marker == true

      # Simulate RTP muxer adding sequence numbers
      # (In real scenario, Membrane.RTP.Muxer would add these)
      rtp_packets =
        payloader_buffers
        |> Enum.with_index()
        |> Enum.map(fn {buffer, idx} ->
          # RTP muxer adds sequence_number and timestamp
          %Buffer{
            buffer
            | metadata:
                Map.update!(buffer.metadata, :rtp, fn rtp ->
                  rtp
                  |> Map.put(:sequence_number, 1000 + idx)
                  |> Map.put(:timestamp, pts)
                end)
          }
        end)

      # Depayloader
      {_actions, dstate} = Depayloader.handle_init(nil, %{clock_rate: 90_000})

      {_dsf_actions, dstate} =
        Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, dstate)

      {out_actions, _dstate} =
        Enum.reduce(rtp_packets, {[], dstate}, fn packet, {acc, st} ->
          {actions, new_state} = Depayloader.handle_buffer(:input, packet, nil, st)
          {acc ++ actions, new_state}
        end)

      # Get depayloader outputs
      output_buffers =
        out_actions
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should reassemble to original access unit
      assert length(output_buffers) == 1
      assert [%Buffer{payload: ^access_unit, pts: ^pts}] = output_buffers
    end

    test "timestamps are preserved through the pipeline" do
      # Multiple access units with different timestamps
      obu1 = OBU.build_obu(:crypto.strong_rand_bytes(100))
      obu2 = OBU.build_obu(:crypto.strong_rand_bytes(150))

      test_cases = [
        {IO.iodata_to_binary([obu1]), 1_000_000},
        {IO.iodata_to_binary([obu2]), 2_000_000}
      ]

      {_actions, pstate} =
        Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})

      {_sf_actions, pstate} = Payloader.handle_stream_format(:input, :any, nil, pstate)

      {_actions, dstate} = Depayloader.handle_init(nil, %{clock_rate: 90_000})

      {_dsf_actions, dstate} =
        Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, dstate)

      Enum.each(test_cases, fn {access_unit, pts} ->
        # Payloader
        {actions, _pstate} =
          Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: pts}, nil, pstate)

        payloader_buffers =
          actions
          |> Enum.flat_map(fn
            {:buffer, {_pad_ref, buffer}} -> [buffer]
            _ -> []
          end)

        # Verify PTS is preserved in payloader output
        Enum.each(payloader_buffers, fn buffer ->
          assert buffer.pts == pts, "PTS should be preserved through payloader"
        end)

        # Simulate RTP muxer adding sequence numbers
        rtp_packets =
          payloader_buffers
          |> Enum.with_index()
          |> Enum.map(fn {buffer, idx} ->
            %Buffer{
              buffer
              | metadata:
                  Map.update!(buffer.metadata, :rtp, fn rtp ->
                    Map.put(rtp, :sequence_number, 1000 + idx)
                  end)
            }
          end)

        # Depayloader
        {out_actions, _dstate} =
          Enum.reduce(rtp_packets, {[], dstate}, fn packet, {acc, st} ->
            {actions, new_state} = Depayloader.handle_buffer(:input, packet, nil, st)
            {acc ++ actions, new_state}
          end)

        output_buffers =
          out_actions
          |> Enum.flat_map(fn
            {:buffer, {_pad_ref, buffer}} -> [buffer]
            _ -> []
          end)

        # Verify PTS is preserved through the entire pipeline
        Enum.each(output_buffers, fn buffer ->
          assert buffer.pts == pts, "PTS should be preserved through entire pipeline"
        end)
      end)
    end
  end
end
