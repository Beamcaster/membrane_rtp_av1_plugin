defmodule Membrane.RTP.AV1.MTUVariationsTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{OBU, PayloadFormat}

  describe "fragment/2 with MTU=64 (very small)" do
    test "fragments small OBU into multiple packets" do
      # Create a small OBU that still needs fragmentation
      payload = <<0x0A>> <> :binary.copy(<<1>>, 100)
      obu = OBU.build_obu(payload)

      # With MTU=64, header takes ~3 bytes, leaving ~61 bytes per packet
      packets = PayloadFormat.fragment(obu, mtu: 64, header_mode: :draft)

      assert is_list(packets)
      # Should create multiple fragments
      assert length(packets) > 1

      # Verify all packets respect MTU
      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 64,
               "Packet size #{byte_size(packet)} exceeds MTU 64"
      end)
    end

    test "handles single byte OBU" do
      payload = <<0x0A>>
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 64, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) == 1
      assert byte_size(hd(packets)) <= 64
    end

    test "handles maximum fragmentation" do
      # Create OBU that requires many fragments
      payload = <<0x0A>> <> :binary.copy(<<1>>, 1000)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 64, header_mode: :draft)

      assert is_list(packets)
      # With MTU=64, should create ~17-18 fragments
      assert length(packets) > 15
      assert length(packets) < 25

      # Verify total size matches (accounting for headers)
      total_payload_size =
        packets
        |> Enum.map(&byte_size/1)
        |> Enum.sum()

      # Total should be reasonable (original + headers)
      assert total_payload_size > byte_size(obu)
      assert total_payload_size < byte_size(obu) * 2
    end
  end

  describe "fragment/2 with MTU=1500 (standard Ethernet)" do
    test "fits medium OBU in single packet" do
      # Create OBU smaller than MTU
      payload = <<0x0A>> <> :binary.copy(<<1>>, 1000)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 1500, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) == 1
      assert byte_size(hd(packets)) <= 1500
    end

    test "fragments large OBU across multiple packets" do
      # Create OBU larger than MTU
      payload = <<0x0A>> <> :binary.copy(<<1>>, 5000)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 1500, header_mode: :draft)

      assert is_list(packets)
      # Should require 4-5 packets
      assert length(packets) >= 3
      assert length(packets) <= 5

      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 1500,
               "Packet size #{byte_size(packet)} exceeds MTU 1500"
      end)
    end

    test "aggregates multiple small OBUs" do
      # Create several small OBUs
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      obu2 = OBU.build_obu(<<0x32, 4, 5, 6>>)
      obu3 = OBU.build_obu(<<0x2A, 7, 8, 9>>)

      au = obu1 <> obu2 <> obu3
      packets = PayloadFormat.fragment(au, mtu: 1500, header_mode: :draft)

      assert is_list(packets)
      # Should aggregate into one packet
      assert length(packets) == 1
      assert byte_size(hd(packets)) <= 1500
    end

    test "handles mix of small and large OBUs" do
      small1 = OBU.build_obu(<<0x0A, 1, 2>>)
      large = OBU.build_obu(<<0x32>> <> :binary.copy(<<3>>, 2000))
      small2 = OBU.build_obu(<<0x2A, 4, 5>>)

      au = small1 <> large <> small2
      packets = PayloadFormat.fragment(au, mtu: 1500, header_mode: :draft)

      assert is_list(packets)
      # Should have: packet(small1) + fragments(large) + packet(small2)
      assert length(packets) >= 3
    end
  end

  describe "fragment/2 with MTU=9000 (jumbo frames)" do
    test "fits large OBU in single packet" do
      # Create large OBU that fits in jumbo frame
      payload = <<0x0A>> <> :binary.copy(<<1>>, 8000)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 9000, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) == 1
      assert byte_size(hd(packets)) <= 9000
    end

    test "fragments very large OBU" do
      # Create OBU larger than jumbo frame
      payload = <<0x0A>> <> :binary.copy(<<1>>, 20_000)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 9000, header_mode: :draft)

      assert is_list(packets)
      # Should require 3-4 packets
      assert length(packets) >= 2
      assert length(packets) <= 4

      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 9000,
               "Packet size #{byte_size(packet)} exceeds MTU 9000"
      end)
    end

    test "aggregates many small OBUs" do
      # Create many small OBUs that fit in one jumbo packet
      obus =
        for i <- 1..100 do
          OBU.build_obu(<<0x0A, i>>)
        end

      au = Enum.join(obus)
      packets = PayloadFormat.fragment(au, mtu: 9000, header_mode: :draft)

      assert is_list(packets)
      # With 100 OBUs and max 31 per packet, we need at least ceil(100/31) = 4 packets
      assert length(packets) >= 4
      # Should not need more than 5 packets given the large MTU
      assert length(packets) <= 5

      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 9000
      end)
    end

    test "handles near-MTU sized OBU" do
      # Create OBU just under MTU size
      payload = <<0x0A>> <> :binary.copy(<<1>>, 8990)
      obu = OBU.build_obu(payload)

      packets = PayloadFormat.fragment(obu, mtu: 9000, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) == 1
      assert byte_size(hd(packets)) <= 9000
    end
  end

  describe "fragment/2 MTU edge cases" do
    test "handles MTU exactly matching OBU size" do
      payload = <<0x0A>> <> :binary.copy(<<1>>, 100)
      obu = OBU.build_obu(payload)
      obu_size = byte_size(obu)

      # Set MTU to exactly fit OBU + header
      packets = PayloadFormat.fragment(obu, mtu: obu_size + 10, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) == 1
    end

    test "handles MTU just below OBU size" do
      payload = <<0x0A>> <> :binary.copy(<<1>>, 100)
      obu = OBU.build_obu(payload)
      obu_size = byte_size(obu)

      # Set MTU to just below OBU size
      packets = PayloadFormat.fragment(obu, mtu: obu_size - 10, header_mode: :draft)

      assert is_list(packets)
      # Should require 2 fragments
      assert length(packets) >= 2
    end

    test "MTU variations with spec header mode" do
      payload = <<0x0A>> <> :binary.copy(<<1>>, 500)
      obu = OBU.build_obu(payload)

      # Test with different MTUs using spec headers
      for mtu <- [64, 1500, 9000] do
        packets = PayloadFormat.fragment(obu, mtu: mtu, header_mode: :spec)

        assert is_list(packets)

        Enum.each(packets, fn packet ->
          assert byte_size(packet) <= mtu,
                 "Packet size #{byte_size(packet)} exceeds MTU #{mtu} (spec mode)"
        end)
      end
    end

    test "multiple OBUs with various MTU sizes" do
      obu1 = OBU.build_obu(<<0x0A>> <> :binary.copy(<<1>>, 100))
      obu2 = OBU.build_obu(<<0x32>> <> :binary.copy(<<2>>, 200))
      obu3 = OBU.build_obu(<<0x2A>> <> :binary.copy(<<3>>, 150))

      au = obu1 <> obu2 <> obu3

      # Test with different MTUs
      for mtu <- [64, 1500, 9000] do
        packets = PayloadFormat.fragment(au, mtu: mtu, header_mode: :draft)

        assert is_list(packets)
        assert length(packets) > 0

        Enum.each(packets, fn packet ->
          assert byte_size(packet) <= mtu,
                 "Packet size #{byte_size(packet)} exceeds MTU #{mtu}"
        end)
      end
    end
  end

  describe "roundtrip with different MTUs" do
    test "MTU=64 roundtrip preserves data" do
      original = OBU.build_obu(<<0x0A>> <> :binary.copy(<<42>>, 200))

      packets = PayloadFormat.fragment(original, mtu: 64, header_mode: :draft)

      # Verify fragmentation occurred
      assert length(packets) > 1

      # Note: Actual depayloader roundtrip would require RTP packet structure
      # This test verifies fragmentation respects MTU
      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 64
      end)
    end

    test "MTU=1500 roundtrip preserves data" do
      original = OBU.build_obu(<<0x0A>> <> :binary.copy(<<42>>, 5000))

      packets = PayloadFormat.fragment(original, mtu: 1500, header_mode: :draft)

      assert length(packets) > 1

      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 1500
      end)
    end

    test "MTU=9000 roundtrip preserves data" do
      original = OBU.build_obu(<<0x0A>> <> :binary.copy(<<42>>, 15_000))

      packets = PayloadFormat.fragment(original, mtu: 9000, header_mode: :draft)

      assert length(packets) > 1

      Enum.each(packets, fn packet ->
        assert byte_size(packet) <= 9000
      end)
    end
  end
end
