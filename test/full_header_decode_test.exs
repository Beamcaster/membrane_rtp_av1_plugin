defmodule Membrane.RTP.AV1.FullHeaderDecodeTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.{Depayloader, FullHeader, ScalabilityStructure}
  import Membrane.RTP.AV1.TestHelperUtils

  @clock_rate 90_000

  describe "Full header decode in depayloader" do
    test "extracts temporal_id and spatial_id from IDS byte" do
      # Create a full header with M=1 (IDS present)
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
      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload = header_bin <> obu_data

      # Create depayloader in spec mode
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send packet with marker bit
      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should output one buffer with av1 metadata
      output_buffer = first_output_buffer(actions)
      assert output_buffer.payload == obu_data
      assert output_buffer.metadata.av1.temporal_id == 3
      assert output_buffer.metadata.av1.spatial_id == 2
      assert output_buffer.metadata.av1.has_ss == false
    end

    test "caches scalability structure when Z=1" do
      # Create a simple scalability structure
      ss = %ScalabilityStructure{
        n_s: 1,
        y_flag: false,
        n_g: 1,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: 30},
          %{width: 3840, height: 2160, frame_rate: 30}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0, 0]}
        ]
      }

      # Create full header with Z=1
      full_header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false,
        scalability_structure: ss
      }

      header_bin = FullHeader.encode(full_header)
      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload1 = header_bin <> obu_data

      # Create depayloader
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send first packet with Z=1
      buffer1 = %Buffer{
        payload: payload1,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions1, state2} = Depayloader.handle_buffer(:input, buffer1, nil, state)

      # Should cache SS
      assert state2.cached_ss == ss
      output1 = first_output_buffer(actions1)
      assert output1.metadata.av1.has_ss == true
      assert output1.metadata.av1.scalability_structure == ss

      # Send second packet with Z=0 (no SS, should use cached)
      full_header2 = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      header_bin2 = FullHeader.encode(full_header2)
      payload2 = header_bin2 <> obu_data

      buffer2 = %Buffer{
        payload: payload2,
        pts: 1000,
        metadata: %{rtp: %{marker: true, sequence_number: 2}}
      }

      {actions2, _state3} = Depayloader.handle_buffer(:input, buffer2, nil, state2)

      # Should use cached SS
      output2 = first_output_buffer(actions2)
      assert output2.metadata.av1.has_ss == false
      assert output2.metadata.av1.scalability_structure == ss
    end

    test "handles both M=1 and Z=1 (IDS + SS)" do
      # Create SS with 3 temporal layers (0, 1, 2) and 2 spatial layers
      ss = %ScalabilityStructure{
        n_s: 1,
        y_flag: true,
        n_g: 3,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: nil},
          %{width: 3840, height: 2160, frame_rate: nil}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0, 0]},
          %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [1, 0]},
          %{temporal_id: 2, spatial_id: 0, reference_count: 1, p_diffs: [1, 0]}
        ]
      }

      # Create full header with both M=1 and Z=1
      full_header = %FullHeader{
        z: true,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: true,
        temporal_id: 2,
        spatial_id: 1,
        scalability_structure: ss
      }

      header_bin = FullHeader.encode(full_header)

      # Verify the header can be decoded
      assert {:ok, decoded_header, _rest} = FullHeader.decode(header_bin)
      assert decoded_header.temporal_id == 2
      assert decoded_header.spatial_id == 1
      assert decoded_header.z == true
      assert decoded_header.scalability_structure != nil

      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload = header_bin <> obu_data

      # Create depayloader
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send packet
      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should have both IDS and SS
      output = first_output_buffer(actions)
      assert output.metadata != nil, "Expected metadata to be present"
      assert output.metadata.av1 != nil, "Expected av1 metadata to be present"
      assert output.metadata.av1.temporal_id == 2
      assert output.metadata.av1.spatial_id == 1
      assert output.metadata.av1.has_ss == true
      assert output.metadata.av1.scalability_structure != nil
    end

    test "extracts N flag (new coded video sequence)" do
      # Create full header with N=1
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: true,
        c: 0,
        m: false
      }

      header_bin = FullHeader.encode(full_header)
      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload = header_bin <> obu_data

      # Create depayloader
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send packet
      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should have N flag set
      output = first_output_buffer(actions)
      assert output.metadata.av1.n_flag == true
    end

    test "extracts Y flag (first OBU in TU)" do
      # Create full header with Y=1
      full_header = %FullHeader{
        z: false,
        y: true,
        w: 0,
        n: false,
        c: 0,
        m: false
      }

      header_bin = FullHeader.encode(full_header)
      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload = header_bin <> obu_data

      # Create depayloader
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send packet
      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should have Y flag set
      output = first_output_buffer(actions)
      assert output.metadata.av1.y_flag == true
    end

    test "handles fragmented packets with full header (W=1,2,3)" do
      # Create 3 packets for a fragmented OBU
      full_header1 = %FullHeader{
        z: false,
        y: true,
        w: 1,
        n: false,
        c: 0,
        m: true,
        temporal_id: 1,
        spatial_id: 0
      }

      full_header2 = %FullHeader{
        z: false,
        y: false,
        w: 2,
        n: false,
        c: 0,
        m: true,
        temporal_id: 1,
        spatial_id: 0
      }

      full_header3 = %FullHeader{
        z: false,
        y: false,
        w: 3,
        n: false,
        c: 0,
        m: true,
        temporal_id: 1,
        spatial_id: 0
      }

      header_bin1 = FullHeader.encode(full_header1)
      header_bin2 = FullHeader.encode(full_header2)
      header_bin3 = FullHeader.encode(full_header3)

      # Split OBU data into 3 parts
      obu_part1 = <<0x12, 0x00, 0x0A>>
      obu_part2 = <<0x0A, 0x00, 0x00>>
      obu_part3 = <<0x00, 0x24>>

      payload1 = header_bin1 <> obu_part1
      payload2 = header_bin2 <> obu_part2
      payload3 = header_bin3 <> obu_part3

      # Create depayloader
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send first fragment (W=1, marker=false)
      buffer1 = %Buffer{
        payload: payload1,
        pts: 0,
        metadata: %{rtp: %{marker: false, sequence_number: 1}}
      }

      {actions1, state2} = Depayloader.handle_buffer(:input, buffer1, nil, state)
      assert actions1 == []

      # Send middle fragment (W=2, marker=false)
      buffer2 = %Buffer{
        payload: payload2,
        pts: 0,
        metadata: %{rtp: %{marker: false, sequence_number: 2}}
      }

      {actions2, state3} = Depayloader.handle_buffer(:input, buffer2, nil, state2)
      assert actions2 == []

      # Send last fragment (W=3, marker=true)
      buffer3 = %Buffer{
        payload: payload3,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 3}}
      }

      {actions3, _state4} = Depayloader.handle_buffer(:input, buffer3, nil, state3)

      # Should output complete OBU with metadata
      output = first_output_buffer(actions3)
      expected_obu = obu_part1 <> obu_part2 <> obu_part3
      assert output.payload == expected_obu
      assert output.metadata.av1.temporal_id == 1
      assert output.metadata.av1.spatial_id == 0
    end

    test "draft mode does not include av1 metadata" do
      # Simple header for draft mode: S=0, E=0, F=0, C=1 (non-fragmented, 1 OBU)
      header_byte = 0b00000001
      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>
      payload = <<header_byte>> <> obu_data

      # Create depayloader in draft mode
      {_actions, state} =
        Depayloader.handle_init(nil, %{
          header_mode: :draft,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      # Send packet with marker bit
      buffer = %Buffer{
        payload: payload,
        pts: 0,
        metadata: %{rtp: %{marker: true, sequence_number: 1}}
      }

      {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)

      # Should not have av1 metadata in draft mode
      output = first_output_buffer(actions)
      assert output.metadata == nil or output.metadata[:av1] == nil
    end

    test "handles multiple temporal layers" do
      # Simulate receiving packets from different temporal layers
      temporal_ids = [0, 1, 2, 0, 1, 0]

      # Create depayloader
      {_actions, initial_state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>

      results =
        Enum.map_reduce(Enum.with_index(temporal_ids, 1), initial_state, fn {tid, seq}, state ->
          full_header = %FullHeader{
            z: false,
            y: true,
            w: 0,
            n: false,
            c: 0,
            m: true,
            temporal_id: tid,
            spatial_id: 0
          }

          header_bin = FullHeader.encode(full_header)
          payload = header_bin <> obu_data

          buffer = %Buffer{
            payload: payload,
            pts: seq * 1000,
            metadata: %{rtp: %{marker: true, sequence_number: seq}}
          }

          {actions, new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)
          {actions, new_state}
        end)

      {outputs, _final_state} = results

      # Verify all temporal IDs were extracted correctly
      extracted_tids =
        Enum.map(outputs, fn actions ->
          buffer = first_output_buffer(actions)
          buffer.metadata.av1.temporal_id
        end)

      assert extracted_tids == temporal_ids
    end

    test "handles multiple spatial layers" do
      # Simulate receiving packets from different spatial layers
      spatial_ids = [0, 1, 2, 0, 1, 0]

      # Create depayloader
      {_actions, initial_state} =
        Depayloader.handle_init(nil, %{
          header_mode: :spec,
          clock_rate: @clock_rate,
          fmtp: %{}
        })

      obu_data = <<0x12, 0x00, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x24>>

      results =
        Enum.map_reduce(Enum.with_index(spatial_ids, 1), initial_state, fn {sid, seq}, state ->
          full_header = %FullHeader{
            z: false,
            y: true,
            w: 0,
            n: false,
            c: 0,
            m: true,
            temporal_id: 0,
            spatial_id: sid
          }

          header_bin = FullHeader.encode(full_header)
          payload = header_bin <> obu_data

          buffer = %Buffer{
            payload: payload,
            pts: seq * 1000,
            metadata: %{rtp: %{marker: true, sequence_number: seq}}
          }

          {actions, new_state} = Depayloader.handle_buffer(:input, buffer, nil, state)
          {actions, new_state}
        end)

      {outputs, _final_state} = results

      # Verify all spatial IDs were extracted correctly
      extracted_sids =
        Enum.map(outputs, fn actions ->
          buffer = first_output_buffer(actions)
          buffer.metadata.av1.spatial_id
        end)

      assert extracted_sids == spatial_ids
    end
  end
end
