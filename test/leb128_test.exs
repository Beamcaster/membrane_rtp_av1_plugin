defmodule Membrane.RTP.AV1.LEB128Test do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.LEB128

  doctest Membrane.RTP.AV1.LEB128

  describe "encode/1" do
    test "encodes zero" do
      assert LEB128.encode(0) == <<0>>
    end

    test "encodes single-byte values" do
      assert LEB128.encode(1) == <<1>>
      assert LEB128.encode(63) == <<63>>
      assert LEB128.encode(127) == <<127>>
    end

    test "encodes two-byte values" do
      assert LEB128.encode(128) == <<128, 1>>
      assert LEB128.encode(255) == <<255, 1>>
      assert LEB128.encode(300) == <<172, 2>>
      assert LEB128.encode(16383) == <<255, 127>>
    end

    test "encodes three-byte values" do
      assert LEB128.encode(16384) == <<128, 128, 1>>
      assert LEB128.encode(100_000) == <<160, 141, 6>>
    end

    test "encodes larger values" do
      assert LEB128.encode(1_000_000) == <<192, 132, 61>>
      assert LEB128.encode(268_435_455) == <<255, 255, 255, 127>>
    end
  end

  describe "read/1" do
    test "reads zero" do
      assert {:ok, 1, 0} = LEB128.read(<<0>>)
    end

    test "reads single-byte values" do
      assert {:ok, 1, 1} = LEB128.read(<<1>>)
      assert {:ok, 1, 63} = LEB128.read(<<63>>)
      assert {:ok, 1, 127} = LEB128.read(<<127>>)
    end

    test "reads two-byte values" do
      assert {:ok, 2, 128} = LEB128.read(<<128, 1>>)
      assert {:ok, 2, 255} = LEB128.read(<<255, 1>>)
      assert {:ok, 2, 300} = LEB128.read(<<172, 2>>)
      assert {:ok, 2, 16383} = LEB128.read(<<255, 127>>)
    end

    test "reads three-byte values" do
      assert {:ok, 3, 16384} = LEB128.read(<<128, 128, 1>>)
      assert {:ok, 3, 100_000} = LEB128.read(<<160, 141, 6>>)
    end

    test "reads larger values" do
      assert {:ok, 3, 1_000_000} = LEB128.read(<<192, 132, 61>>)
      assert {:ok, 4, 268_435_455} = LEB128.read(<<255, 255, 255, 127>>)
    end

    test "ignores trailing data" do
      assert {:ok, 1, 42} = LEB128.read(<<42, 99, 100, 101>>)
      assert {:ok, 2, 300} = LEB128.read(<<172, 2, 0, 0, 0>>)
    end

    test "returns error for empty input" do
      assert {:error, :invalid_leb128_data} = LEB128.read(<<>>)
    end

    test "returns error for truncated multi-byte value" do
      assert {:error, :invalid_leb128_data} = LEB128.read(<<128>>)
      assert {:error, :invalid_leb128_data} = LEB128.read(<<128, 128>>)
    end
  end

  describe "roundtrip" do
    test "encode then read returns original value" do
      test_values = [0, 1, 127, 128, 255, 256, 1000, 16383, 16384, 100_000, 1_000_000]

      for value <- test_values do
        encoded = LEB128.encode(value)
        assert {:ok, _size, ^value} = LEB128.read(encoded)
      end
    end

    test "roundtrip preserves all values up to 1000" do
      for value <- 0..1000 do
        encoded = LEB128.encode(value)
        assert {:ok, _size, ^value} = LEB128.read(encoded)
      end
    end
  end
end
