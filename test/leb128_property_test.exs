defmodule Membrane.RTP.AV1.LEB128PropertyTest do
  @moduledoc """
  Property-based tests for `Membrane.RTP.AV1.LEB128`.

  Invariants trace to the AV1 bitstream specification section 4.10.5 (`leb128()`).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Membrane.RTP.AV1.LEB128
  alias Membrane.RTP.AV1.Test.AV1Generators, as: Gen

  @moduletag :property

  property "encode then read recovers the original value" do
    check all(value <- Gen.leb128_value()) do
      encoded = LEB128.encode(value)
      assert {:ok, byte_count, ^value} = LEB128.read(encoded)
      assert byte_count == byte_size(encoded)
    end
  end

  property "encoded length is the minimal byte count for the value" do
    check all(value <- Gen.leb128_value()) do
      encoded = LEB128.encode(value)
      assert byte_size(encoded) == minimal_byte_count(value)
      assert byte_size(encoded) <= 8
    end
  end

  property "encoding is minimal: last byte clears the continuation bit" do
    check all(value <- Gen.leb128_value()) do
      encoded = LEB128.encode(value)
      last_byte = :binary.last(encoded)

      assert (last_byte &&& 0x80) == 0

      if byte_size(encoded) > 1 do
        assert last_byte != 0,
               "a trailing zero byte means a redundant continuation byte was emitted"
      end
    end
  end

  property "read consumes only the LEB128 prefix and ignores trailing data" do
    check all(value <- Gen.leb128_value(), trailing <- StreamData.binary()) do
      encoded = LEB128.encode(value)
      assert {:ok, byte_count, ^value} = LEB128.read(encoded <> trailing)
      assert byte_count == byte_size(encoded)
    end
  end

  property "truncated input made only of continuation bytes is rejected" do
    check all(truncated <- Gen.truncated_leb128()) do
      assert {:error, :invalid_leb128_data} = LEB128.read(truncated)
    end
  end

  property "read returns a well-formed result and never raises on arbitrary input" do
    check all(data <- StreamData.binary()) do
      case LEB128.read(data) do
        {:ok, byte_count, value} ->
          assert is_integer(byte_count) and byte_count > 0
          assert is_integer(value) and value >= 0

        {:error, :invalid_leb128_data} ->
          :ok
      end
    end
  end

  # AV1 bitstream spec section 4.10.5 limits a leb128() to at most 8 bytes (and
  # its decoded value to 32 bits). Neither `encode/2` nor `read/4` enforces this
  # bound. This property documents the current lenient behaviour: encoding a
  # value that needs more than 56 bits yields a non-conformant binary longer
  # than 8 bytes, which `read/4` then accepts. Callers must keep OBU sizes and
  # aggregation lengths within the AV1-valid range. See findings list.
  property "encode/read round-trip values beyond the AV1 8-byte leb128 limit" do
    check all(value <- Gen.leb128_oversize_value()) do
      encoded = LEB128.encode(value)
      assert byte_size(encoded) > 8
      assert {:ok, byte_count, ^value} = LEB128.read(encoded)
      assert byte_count == byte_size(encoded)
    end
  end

  defp minimal_byte_count(0), do: 1
  defp minimal_byte_count(value) when value > 0, do: count_groups(value, 0)

  defp count_groups(0, acc), do: acc
  defp count_groups(value, acc), do: count_groups(value >>> 7, acc + 1)
end
