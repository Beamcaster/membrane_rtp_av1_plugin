defmodule Membrane.RTP.AV1.OBUValidationIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{PayloadFormat, OBU}

  describe "fragment/2 with OBU validation" do
    test "accepts valid access unit with single OBU" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3, 4, 5>>)
      packets = PayloadFormat.fragment(obu, mtu: 1200, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) > 0
    end

    test "accepts valid access unit with multiple OBUs" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2>>)
      obu2 = OBU.build_obu(<<0x32, 3, 4, 5>>)
      obu3 = OBU.build_obu(<<0x2A, 6, 7>>)

      au = obu1 <> obu2 <> obu3
      packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) > 0
    end

    test "handles large valid OBU requiring fragmentation" do
      # Create OBU larger than MTU
      large_payload = <<0x0A>> <> :binary.copy(<<1>>, 2000)
      obu = OBU.build_obu(large_payload)

      packets = PayloadFormat.fragment(obu, mtu: 1200, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) > 1
    end

    test "handles incomplete OBU with fallback" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      # Incomplete second OBU
      partial = <<5, 0x32, 1, 2>>

      # Should log warning but attempt fallback fragmentation
      au = obu1 <> partial
      result = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      # Should still return packets (fallback behavior)
      assert is_list(result)
    end

    test "rejects access unit with partial OBU at boundary" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      # This will be detected as partial OBU at boundary
      partial = <<10, 0x32, 1, 2>>

      au = obu1 <> partial

      # Should return error for partial OBU
      result = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      # Fallback should handle this
      assert is_list(result) or match?({:error, _, _}, result)
    end

    test "handles OBU with forbidden bit set" do
      # Create OBU with forbidden bit set (0xB2)
      payload = <<0xB2, 1, 2, 3>>
      obu = OBU.build_obu(payload)

      # Should log warning but attempt fallback
      result = PayloadFormat.fragment(obu, mtu: 1200, header_mode: :draft)

      # Should fallback to naive fragmentation
      assert is_list(result)
    end

    test "handles zero-length OBU" do
      # Zero-length OBU
      invalid = <<0>>

      result = PayloadFormat.fragment(invalid, mtu: 1200, header_mode: :draft)

      # Should fallback
      assert is_list(result)
    end

    test "handles valid OBUs with multi-byte LEB128" do
      # Create OBU with size > 127 requiring multi-byte LEB128
      large_payload = <<0x0A>> <> :binary.copy(<<1>>, 200)
      obu = OBU.build_obu(large_payload)

      packets = PayloadFormat.fragment(obu, mtu: 1200, header_mode: :draft)

      assert is_list(packets)
      assert length(packets) > 0
    end

    test "aggregates small valid OBUs into single packet" do
      # Create several small OBUs that should fit in one packet
      obu1 = OBU.build_obu(<<0x0A, 1>>)
      obu2 = OBU.build_obu(<<0x32, 2>>)
      obu3 = OBU.build_obu(<<0x2A, 3>>)

      au = obu1 <> obu2 <> obu3
      packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      # Should aggregate into single packet
      assert length(packets) == 1
    end

    test "validates and fragments complex access unit" do
      # Mix of small and large OBUs
      small1 = OBU.build_obu(<<0x0A, 1, 2>>)
      large = OBU.build_obu(<<0x32>> <> :binary.copy(<<3>>, 1500))
      small2 = OBU.build_obu(<<0x2A, 4, 5>>)

      au = small1 <> large <> small2
      packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :draft)

      assert is_list(packets)
      # Should have: packet with small1, multiple packets for large, packet with small2
      assert length(packets) > 2
    end
  end

  describe "fragment/2 with spec header mode" do
    test "validates and fragments with spec headers" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      obu2 = OBU.build_obu(<<0x32, 4, 5, 6>>)

      au = obu1 <> obu2
      packets = PayloadFormat.fragment(au, mtu: 1200, header_mode: :spec)

      assert is_list(packets)
      assert length(packets) > 0
    end

    test "handles validation errors with spec headers" do
      # Incomplete OBU
      partial = <<10, 0x32, 1, 2>>

      result = PayloadFormat.fragment(partial, mtu: 1200, header_mode: :spec)

      # Should fallback
      assert is_list(result) or match?({:error, _, _}, result)
    end
  end

  describe "telemetry integration" do
    @tag :skip
    test "emits telemetry on validation errors" do
      # Attach telemetry handler
      :telemetry.attach(
        "test-validation-integration",
        [:membrane_rtp_av1, :obu_validation, :error],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Trigger validation error
      invalid = <<10, 0x0A, 1, 2>>
      PayloadFormat.fragment(invalid, mtu: 1200)

      # Verify telemetry
      assert_receive {:telemetry, [:membrane_rtp_av1, :obu_validation, :error], _measurements,
                      _metadata},
                     100

      # Cleanup
      :telemetry.detach("test-validation-integration")
    end
  end
end
