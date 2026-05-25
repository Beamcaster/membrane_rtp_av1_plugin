defmodule Membrane.RTP.AV1.DepayloaderPropertyTest do
  @moduledoc """
  Property-based tests for `Membrane.RTP.AV1.Depayloader`.

  Invariants trace to RFC 9628 sections 4.2 (temporal units), 4.3 (W field),
  4.3.2 (Z/Y fragmentation) and 4.4 (N bit), and the AV1 bitstream spec
  section 5.3 (OBU syntax).

  Comparisons are made on the semantic OBU fields
  (`{type, has_extension, temporal_id, spatial_id, payload}`) because the
  depayloader normalizes every OBU to carry a size field and prepends a
  canonical temporal delimiter.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Membrane.RTP.AV1.TestHelperUtils

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.RTP.AV1.Test.AV1Generators, as: Gen

  @moduletag :property
  @moduletag capture_log: true

  property "a keyframe temporal unit round-trips through the depayloader" do
    check all(temporal_unit <- Gen.keyframe_temporal_unit()) do
      buffers =
        temporal_unit
        |> Gen.packetize(0, 1)
        |> Gen.to_buffers(1_000)

      {actions, _state} = Gen.run_depayloader(buffers)

      assert [%Buffer{} = output] = extract_output_buffers(actions)
      assert output.metadata.av1.key_frame? == true

      [delimiter | obus] = Gen.split_obus(output.payload)
      assert delimiter.type == 2 and delimiter.payload == <<>>
      assert Gen.semantics(obus) == Gen.semantics(temporal_unit)
    end
  end

  property "the W field framing does not change the reconstructed temporal unit" do
    check all(
            temporal_unit <- Gen.keyframe_temporal_unit(),
            w <- StreamData.integer(0..3)
          ) do
      baseline = depayload_once(Gen.packetize(temporal_unit, 0, 1))
      variant = depayload_once(Gen.packetize(temporal_unit, w, 1))

      assert variant == baseline
    end
  end

  property "OBU fragmentation does not change the reconstructed temporal unit" do
    check all(
            temporal_unit <- Gen.keyframe_temporal_unit(),
            frag_index <- StreamData.integer(0..50),
            pieces <- StreamData.integer(2..3)
          ) do
      baseline = depayload_once(Gen.packetize(temporal_unit, 1, 1))
      fragmented = depayload_once(Gen.packetize_fragmented(temporal_unit, frag_index, pieces, 1))

      assert fragmented == baseline
    end
  end

  property "a keyframe followed by inter frames yields one output per temporal unit" do
    check all(
            keyframe <- Gen.keyframe_temporal_unit(),
            inter_units <- StreamData.list_of(Gen.inter_temporal_unit(), max_length: 4)
          ) do
      temporal_units = [keyframe | inter_units]

      buffers =
        temporal_units
        |> Enum.with_index()
        |> Enum.flat_map(fn {temporal_unit, index} ->
          n_bit = if index == 0, do: 1, else: 0

          temporal_unit
          |> Gen.packetize(0, n_bit)
          |> Gen.to_buffers(1_000 + index * 3_000)
        end)

      {actions, _state} = Gen.run_depayloader(buffers)
      outputs = extract_output_buffers(actions)

      assert length(outputs) == length(temporal_units)

      [keyframe_output | inter_outputs] = outputs
      assert keyframe_output.metadata.av1.key_frame? == true
      assert Enum.all?(inter_outputs, &(&1.metadata.av1.key_frame? == false))

      [keyframe_delimiter | keyframe_obus] = Gen.split_obus(keyframe_output.payload)
      assert keyframe_delimiter.type == 2
      assert Gen.semantics(keyframe_obus) == Gen.semantics(keyframe)

      sequence_header = keyframe |> Enum.find(&(&1.type == 1)) |> Gen.semantic()

      inter_outputs
      |> Enum.zip(inter_units)
      |> Enum.each(fn {output, inter_unit} ->
        [delimiter, cached_header | inter_obus] = Gen.split_obus(output.payload)
        assert delimiter.type == 2
        assert Gen.semantic(cached_header) == sequence_header
        assert Gen.semantics(inter_obus) == Gen.semantics(inter_unit)
      end)
    end
  end

  property "parse_obu_header reports the fields of a generated OBU" do
    check all(obu <- Gen.obu()) do
      assert {:ok, info} = Depayloader.parse_obu_header(obu.bytes)
      assert info.type == obu.type
      assert info.has_extension == obu.has_extension
      assert info.has_size == obu.has_size

      if obu.has_extension do
        assert info.extension.temporal_id == obu.temporal_id
        assert info.extension.spatial_id == obu.spatial_id
      end
    end
  end

  property "parse_obu_header falls back when the claimed extension byte is absent" do
    check all(header_byte <- Gen.obu_header_only_with_extension()) do
      assert {:ok, info} = Depayloader.parse_obu_header(header_byte)
      assert info.has_extension == true
      assert info.extension == nil
      assert info.header_bytes == 1
    end
  end

  property "parse_obu_header rejects a set forbidden bit" do
    check all(
            low_bits <- StreamData.integer(0..127),
            rest <- StreamData.binary()
          ) do
      assert {:error, :forbidden_bit_set} =
               Depayloader.parse_obu_header(<<1::1, low_bits::7>> <> rest)
    end
  end

  property "handle_buffer never raises on arbitrary RTP payloads" do
    check all(
            payload <- StreamData.binary(),
            marker <- StreamData.boolean()
          ) do
      buffer = rtp_buffer(payload, marker)
      result = Depayloader.handle_buffer(:input, buffer, %{}, Gen.fresh_state())

      assert {actions, %Depayloader.State{}} = result
      assert is_list(actions)
    end
  end

  property "handle_buffer never raises on well-formed but arbitrary aggregation payloads" do
    check all(
            z <- StreamData.integer(0..1),
            y <- StreamData.integer(0..1),
            w <- StreamData.integer(0..3),
            n <- StreamData.integer(0..1),
            body <- StreamData.binary(min_length: 1),
            marker <- StreamData.boolean()
          ) do
      payload = <<z::1, y::1, w::2, n::1, 0::3>> <> body
      buffer = rtp_buffer(payload, marker)
      result = Depayloader.handle_buffer(:input, buffer, %{}, Gen.fresh_state())

      assert {actions, %Depayloader.State{}} = result
      assert is_list(actions)
    end
  end

  property "a packet that fails to parse resets the in-progress temporal unit" do
    check all(
            fields <- StreamData.integer(0..0b11111),
            reserved <- StreamData.integer(1..7),
            body <- StreamData.binary(min_length: 1),
            marker <- StreamData.boolean()
          ) do
      payload = <<fields::5, reserved::3>> <> body

      state = %{
        Gen.fresh_state()
        | current_temporal_unit: <<1, 2, 3>>,
          current_obu_fragment: <<4, 5>>,
          current_timestamp: 99
      }

      {actions, new_state} =
        Depayloader.handle_buffer(:input, rtp_buffer(payload, marker), %{}, state)

      assert actions == []
      assert new_state.current_temporal_unit == nil
      assert new_state.current_obu_fragment == nil
    end
  end

  defp depayload_once(packets) do
    {actions, _state} =
      packets
      |> Gen.to_buffers(1_000)
      |> Gen.run_depayloader()

    assert [output] = extract_output_buffers(actions)
    output.payload
  end

  defp rtp_buffer(payload, marker) do
    %Buffer{
      payload: payload,
      pts: nil,
      metadata: %{
        rtp: %{timestamp: 1_000, marker: marker, sequence_number: 1, ssrc: 1, payload_type: 96}
      }
    }
  end
end
