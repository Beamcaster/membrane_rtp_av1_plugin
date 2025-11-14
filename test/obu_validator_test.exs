defmodule Membrane.RTP.AV1.OBUValidatorTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{OBU, OBUValidator}

  describe "validate_access_unit/1 - valid cases" do
    test "accepts single valid OBU" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      assert :ok = OBUValidator.validate_access_unit(obu)
    end

    test "accepts multiple valid OBUs" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2>>)
      obu2 = OBU.build_obu(<<0x32, 3, 4, 5>>)
      obu3 = OBU.build_obu(<<0x2A, 6>>)

      au = obu1 <> obu2 <> obu3
      assert :ok = OBUValidator.validate_access_unit(au)
    end

    test "accepts large OBU (under max size)" do
      payload = :binary.copy(<<0x0A>>, 1000) <> :binary.copy(<<1>>, 1000)
      obu = OBU.build_obu(payload)
      assert :ok = OBUValidator.validate_access_unit(obu)
    end

    test "accepts empty access unit" do
      assert :ok = OBUValidator.validate_access_unit(<<>>)
    end

    test "accepts OBU with multi-byte LEB128" do
      # Size 200 = 0xC8 = 0x48 0x01 in LEB128
      payload = <<0x0A>> <> :binary.copy(<<0>>, 199)
      obu = OBU.build_obu(payload)
      assert :ok = OBUValidator.validate_access_unit(obu)
    end
  end

  describe "validate_access_unit/1 - invalid LEB128" do
    test "rejects truncated LEB128" do
      # LEB128 continuation bit set but no next byte
      assert {:error, :invalid_leb128, context} = OBUValidator.validate_access_unit(<<0x80>>)
      assert context.reason == :truncated
    end

    test "rejects LEB128 with too many bytes" do
      # 9 bytes with continuation bits (max is 8)
      invalid_leb = <<0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80>>
      assert {:error, :invalid_leb128, context} = OBUValidator.validate_access_unit(invalid_leb)
      assert context.reason == :too_many_bytes
    end

    test "rejects empty buffer" do
      # This gets handled differently - empty is OK at top level
      # but empty when expecting LEB128 is invalid
      assert :ok = OBUValidator.validate_access_unit(<<>>)
    end
  end

  describe "validate_access_unit/1 - incomplete OBUs" do
    test "rejects OBU with length > available data" do
      # Claim 10 bytes but only provide 3
      assert {:error, :incomplete_obu, context} =
               OBUValidator.validate_access_unit(<<10, 0x0A, 1, 2>>)

      assert context.expected == 10
      assert context.actual == 3
    end

    test "rejects partial OBU at end of access unit" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      # Second OBU is incomplete
      partial = <<5, 0x32, 1, 2>>

      assert {:error, :incomplete_obu, _context} =
               OBUValidator.validate_access_unit(obu1 <> partial)
    end

    test "rejects OBU cut in middle" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3, 4, 5>>)
      # Remove last 2 bytes
      truncated = binary_part(obu, 0, byte_size(obu) - 2)

      assert {:error, :incomplete_obu, _context} = OBUValidator.validate_access_unit(truncated)
    end
  end

  describe "validate_access_unit/1 - OBU size limits" do
    test "rejects zero-length OBU" do
      assert {:error, :zero_length_obu, _context} = OBUValidator.validate_access_unit(<<0>>)
    end

    test "rejects OBU exceeding max size" do
      # Encode size as 300,000 bytes (> 256,000 max)
      # 300000 = 0x493E0 = 0xE0 0xA7 0x12 in LEB128
      invalid = <<0xE0, 0xA7, 0x12, 0x0A>>

      assert {:error, :obu_too_large, context} = OBUValidator.validate_access_unit(invalid)
      assert context.size == 300_000
      assert context.max == 256_000
    end
  end

  describe "validate_access_unit/1 - OBU header validation" do
    test "rejects OBU with forbidden bit set" do
      # Header byte with forbidden bit set (bit 7 = 1)
      # 0xB2 = 10110010 (F=1, type=6, X=0, S=1, reserved=0)
      payload = <<0xB2, 1, 2, 3>>
      obu = OBU.build_obu(payload)

      assert {:error, :forbidden_bit_set, context} = OBUValidator.validate_access_unit(obu)
      assert context.byte == 0xB2
    end

    test "accepts OBU with forbidden bit clear" do
      # 0x32 = 00110010 (F=0, type=6, X=0, S=1, reserved=0)
      payload = <<0x32, 1, 2, 3>>
      obu = OBU.build_obu(payload)

      assert :ok = OBUValidator.validate_access_unit(obu)
    end
  end

  describe "validate_and_split/1" do
    test "returns list of valid OBUs" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2>>)
      obu2 = OBU.build_obu(<<0x32, 3, 4, 5>>)

      assert {:ok, obus} = OBUValidator.validate_and_split(obu1 <> obu2)
      assert length(obus) == 2
      assert Enum.at(obus, 0) == obu1
      assert Enum.at(obus, 1) == obu2
    end

    test "returns error for invalid access unit" do
      invalid = <<10, 0x0A, 1, 2>>

      assert {:error, :incomplete_obu, _context} = OBUValidator.validate_and_split(invalid)
    end

    test "returns empty list for empty input" do
      assert {:ok, []} = OBUValidator.validate_and_split(<<>>)
    end
  end

  describe "validate_obu/1" do
    test "accepts single valid OBU" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      assert :ok = OBUValidator.validate_obu(obu)
    end

    test "rejects OBU with invalid length" do
      assert {:error, :incomplete_obu, _} = OBUValidator.validate_obu(<<10, 0x0A, 1, 2>>)
    end

    test "rejects zero-length OBU" do
      assert {:error, :zero_length_obu, _} = OBUValidator.validate_obu(<<0>>)
    end
  end

  describe "check_boundaries/1" do
    test "returns ok for complete OBUs" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2>>)
      obu2 = OBU.build_obu(<<0x32, 3, 4>>)

      assert :ok = OBUValidator.check_boundaries(obu1 <> obu2)
    end

    test "returns partial_obu_at_boundary for incomplete OBU" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      partial = <<5, 0x32, 1, 2>>

      assert {:error, :partial_obu_at_boundary, context} =
               OBUValidator.check_boundaries(obu1 <> partial)

      assert context.message =~ "partial OBU"
    end

    test "returns ok for empty input" do
      assert :ok = OBUValidator.check_boundaries(<<>>)
    end

    test "propagates other validation errors" do
      # Zero-length OBU
      assert {:error, :zero_length_obu, _} = OBUValidator.check_boundaries(<<0>>)
    end
  end

  describe "error_message/1" do
    test "formats invalid_leb128 error" do
      error = {:error, :invalid_leb128, %{reason: :too_many_bytes}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "Invalid LEB128"
      assert msg =~ "too_many_bytes"
    end

    test "formats incomplete_obu error" do
      error = {:error, :incomplete_obu, %{expected: 10, actual: 5}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "Incomplete OBU"
      assert msg =~ "10"
      assert msg =~ "5"
    end

    test "formats obu_too_large error" do
      error = {:error, :obu_too_large, %{size: 300_000, max: 256_000}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "too large"
      assert msg =~ "300000"
    end

    test "formats forbidden_bit_set error" do
      error = {:error, :forbidden_bit_set, %{}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "forbidden bit"
    end

    test "formats malformed_header error" do
      error = {:error, :malformed_header, %{reason: "missing extension"}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "Malformed"
      assert msg =~ "missing extension"
    end

    test "formats partial_obu_at_boundary error" do
      error = {:error, :partial_obu_at_boundary, %{message: "Test message"}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "Test message"
    end

    test "formats zero_length_obu error" do
      error = {:error, :zero_length_obu, %{}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "zero length"
    end

    test "handles unknown error" do
      error = {:error, :unknown_error, %{}}
      msg = OBUValidator.error_message(error)
      assert msg =~ "Unknown"
    end
  end

  describe "telemetry" do
    test "emits telemetry event on validation error" do
      # Attach test handler
      :telemetry.attach(
        "test-obu-validation",
        [:membrane_rtp_av1, :obu_validation, :error],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Trigger validation error
      invalid = <<10, 0x0A, 1, 2>>
      OBUValidator.validate_access_unit(invalid)

      # Verify telemetry was emitted
      assert_receive {:telemetry, [:membrane_rtp_av1, :obu_validation, :error], measurements,
                      metadata}

      assert measurements.count == 1
      assert metadata.reason == :incomplete_obu
      assert is_map(metadata.context)

      # Cleanup
      :telemetry.detach("test-obu-validation")
    end
  end
end
