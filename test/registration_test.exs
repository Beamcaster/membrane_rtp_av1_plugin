defmodule Membrane.RTP.AV1.RegistrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.PayloadFormat

  describe "AV1 payload format registration" do
    test "encoding name is registered" do
      format = PayloadFormat.get(:AV1)
      assert format.encoding_name == :AV1
    end

    test "payloader is registered" do
      format = PayloadFormat.get(:AV1)
      assert format.payloader == Membrane.RTP.AV1.Payloader
    end

    test "depayloader is registered" do
      format = PayloadFormat.get(:AV1)
      assert format.depayloader == Membrane.RTP.AV1.Depayloader
    end

    test "clock rate is not specified in registration" do
      # AV1 uses dynamic payload types (96-127), so clock rate
      # is determined from SDP negotiation, not from registration
      format = PayloadFormat.get(:AV1)
      assert format.payload_type == nil
    end

    test "resolve can find AV1 format" do
      result = PayloadFormat.resolve(encoding_name: :AV1, clock_rate: 90_000)

      assert result.payload_format != nil
      assert result.payload_format.encoding_name == :AV1
      assert result.clock_rate == 90_000
    end

    test "resolve can find payloader" do
      result = PayloadFormat.resolve(encoding_name: :AV1)

      assert result.payload_format.payloader == Membrane.RTP.AV1.Payloader
    end

    test "resolve can find depayloader" do
      result = PayloadFormat.resolve(encoding_name: :AV1)

      assert result.payload_format.depayloader == Membrane.RTP.AV1.Depayloader
    end

    test "Membrane.RTP.AV1 provides encoding_name helper" do
      assert Membrane.RTP.AV1.encoding_name() == :AV1
    end

    test "Membrane.RTP.AV1 provides clock_rate helper" do
      assert Membrane.RTP.AV1.clock_rate() == 90_000
    end
  end
end
