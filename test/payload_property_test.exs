defmodule Membrane.RTP.AV1.PayloadPropertyTest do
  @moduledoc """
  Property-based tests for `Membrane.RTP.AV1.ExWebRTC.Payload`.

  Invariants trace to RFC 9628 sections 4.3 (W field), 4.3.2 (Z/Y
  fragmentation) and 4.4 (aggregation header).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Membrane.RTP.AV1.ExWebRTC.Payload

  @moduletag :property

  property "serialize then parse recovers the struct" do
    check all(payload <- payload_struct()) do
      assert {:ok, ^payload} = Payload.parse(Payload.serialize(payload))
    end
  end

  property "parse then serialize recovers the binary" do
    check all(payload <- payload_struct()) do
      binary = Payload.serialize(payload)
      assert {:ok, parsed} = Payload.parse(binary)
      assert Payload.serialize(parsed) == binary
    end
  end

  property "the serialized header carries the bit fields with zero reserved bits" do
    check all(payload <- payload_struct()) do
      <<z::1, y::1, w::2, n::1, reserved::3, rest::binary>> = Payload.serialize(payload)

      assert {z, y, w, n} == {payload.z, payload.y, payload.w, payload.n}
      assert reserved == 0
      assert rest == payload.payload
    end
  end

  property "a packet with no payload bytes is rejected" do
    check all(header <- StreamData.integer(0..255)) do
      assert {:error, :invalid_packet} = Payload.parse(<<header>>)
    end
  end

  property "a packet with non-zero reserved bits is rejected" do
    check all(
            fields <- StreamData.integer(0..0b11111),
            reserved <- StreamData.integer(1..7),
            rest <- StreamData.binary(min_length: 1)
          ) do
      assert {:error, :invalid_packet} = Payload.parse(<<fields::5, reserved::3>> <> rest)
    end
  end

  property "parse never raises on arbitrary input" do
    check all(data <- StreamData.binary()) do
      case Payload.parse(data) do
        {:ok, %Payload{}} -> :ok
        {:error, :invalid_packet} -> :ok
      end
    end
  end

  property "payload_obu_fragments sets Z/Y bits per RFC 9628 section 4.3.2" do
    check all(fragments <- obu_fragments(), n_bit <- StreamData.integer(0..1)) do
      result = Payload.payload_obu_fragments(fragments, n_bit)

      assert length(result) == length(fragments)
      assert Enum.all?(result, &(&1.w == 1))

      case result do
        [single] ->
          assert {single.z, single.y} == {0, 0}

        [first | rest] ->
          assert {first.z, first.y} == {0, 1}
          {middles, [last]} = Enum.split(rest, length(rest) - 1)
          assert Enum.all?(middles, &({&1.z, &1.y} == {1, 1}))
          assert {last.z, last.y} == {1, 0}
      end
    end
  end

  property "payload_obu_fragments applies the N bit only to the first element" do
    check all(fragments <- obu_fragments(), n_bit <- StreamData.integer(0..1)) do
      [first | rest] = Payload.payload_obu_fragments(fragments, n_bit)

      assert first.n == n_bit
      assert Enum.all?(rest, &(&1.n == 0))
    end
  end

  property "payload_obu_fragments partitions the OBU without losing or reordering bytes" do
    check all(fragments <- obu_fragments(), n_bit <- StreamData.integer(0..1)) do
      result = Payload.payload_obu_fragments(fragments, n_bit)

      assert Enum.map(result, & &1.payload) == fragments

      assert IO.iodata_to_binary(Enum.map(result, & &1.payload)) ==
               IO.iodata_to_binary(fragments)
    end
  end

  defp payload_struct do
    gen all(
          z <- StreamData.integer(0..1),
          y <- StreamData.integer(0..1),
          w <- StreamData.integer(0..3),
          n <- StreamData.integer(0..1),
          data <- StreamData.binary(min_length: 1)
        ) do
      %Payload{z: z, y: y, w: w, n: n, payload: data}
    end
  end

  defp obu_fragments do
    StreamData.list_of(StreamData.binary(min_length: 1), min_length: 1, max_length: 6)
  end
end
