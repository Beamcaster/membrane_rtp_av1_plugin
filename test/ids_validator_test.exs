defmodule Membrane.RTP.AV1.IDSValidatorTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Membrane.RTP.AV1.{IDSValidator, ScalabilityStructure}

  describe "validate_ids_byte/1" do
    test "accepts valid IDS byte with TID=0, LID=0" do
      # 000 00 000
      assert :ok = IDSValidator.validate_ids_byte(0b00000000)
    end

    test "accepts valid IDS byte with TID=7, LID=3" do
      # 111 11 000
      assert :ok = IDSValidator.validate_ids_byte(0b11111000)
    end

    test "accepts valid IDS byte with TID=3, LID=1" do
      # 011 01 000
      assert :ok = IDSValidator.validate_ids_byte(0b01101000)
    end

    test "rejects IDS byte with reserved bit 0 set" do
      # 011 01 001
      assert {:error, :reserved_kid_bits_set} = IDSValidator.validate_ids_byte(0b01101001)
    end

    test "rejects IDS byte with reserved bit 1 set" do
      # 011 01 010
      assert {:error, :reserved_kid_bits_set} = IDSValidator.validate_ids_byte(0b01101010)
    end

    test "rejects IDS byte with reserved bit 2 set" do
      # 011 01 100
      assert {:error, :reserved_kid_bits_set} = IDSValidator.validate_ids_byte(0b01101100)
    end

    test "rejects IDS byte with all reserved bits set" do
      # 011 01 111
      assert {:error, :reserved_kid_bits_set} = IDSValidator.validate_ids_byte(0b01101111)
    end

    test "rejects invalid byte format (non-integer)" do
      assert {:error, :invalid_ids_byte} = IDSValidator.validate_ids_byte("invalid")
    end

    test "rejects negative integer" do
      assert {:error, :invalid_ids_byte} = IDSValidator.validate_ids_byte(-1)
    end

    test "rejects integer > 255" do
      assert {:error, :invalid_ids_byte} = IDSValidator.validate_ids_byte(256)
    end
  end

  describe "validate_ids/2" do
    test "accepts valid temporal_id and spatial_id" do
      assert :ok = IDSValidator.validate_ids(0, 0)
      assert :ok = IDSValidator.validate_ids(7, 3)
      assert :ok = IDSValidator.validate_ids(3, 1)
    end

    test "rejects temporal_id > 7" do
      assert {:error, :invalid_temporal_id} = IDSValidator.validate_ids(8, 0)
    end

    test "rejects negative temporal_id" do
      assert {:error, :invalid_temporal_id} = IDSValidator.validate_ids(-1, 0)
    end

    test "rejects spatial_id > 3" do
      assert {:error, :invalid_spatial_id} = IDSValidator.validate_ids(0, 4)
    end

    test "rejects negative spatial_id" do
      assert {:error, :invalid_spatial_id} = IDSValidator.validate_ids(0, -1)
    end

    test "rejects nil temporal_id" do
      assert {:error, :missing_ids} = IDSValidator.validate_ids(nil, 0)
    end

    test "rejects nil spatial_id" do
      assert {:error, :missing_ids} = IDSValidator.validate_ids(0, nil)
    end

    test "rejects both nil" do
      assert {:error, :missing_ids} = IDSValidator.validate_ids(nil, nil)
    end
  end

  describe "validate_ids_with_capabilities/3 - without SS" do
    test "validates basic ranges when SS is nil" do
      assert :ok = IDSValidator.validate_ids_with_capabilities(3, 1, nil)
      assert :ok = IDSValidator.validate_ids_with_capabilities(0, 0, nil)
      assert :ok = IDSValidator.validate_ids_with_capabilities(7, 3, nil)
    end

    test "rejects out-of-range values even without SS" do
      assert {:error, :invalid_temporal_id} =
               IDSValidator.validate_ids_with_capabilities(8, 0, nil)

      assert {:error, :invalid_spatial_id} =
               IDSValidator.validate_ids_with_capabilities(0, 4, nil)
    end
  end

  describe "validate_ids_with_capabilities/3 - with SS (simple stream)" do
    setup do
      # Simple stream: 1 spatial layer (1920x1080), 3 temporal layers (0, 1, 2)
      ss = %ScalabilityStructure{
        n_s: 0,
        y_flag: false,
        n_g: 3,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: 30}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: []},
          %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [1]},
          %{temporal_id: 2, spatial_id: 0, reference_count: 1, p_diffs: [1]}
        ]
      }

      {:ok, ss: ss}
    end

    test "accepts TID within capability", %{ss: ss} do
      assert :ok = IDSValidator.validate_ids_with_capabilities(0, 0, ss)
      assert :ok = IDSValidator.validate_ids_with_capabilities(1, 0, ss)
      assert :ok = IDSValidator.validate_ids_with_capabilities(2, 0, ss)
    end

    test "rejects TID exceeding capability", %{ss: ss} do
      assert {:error, :temporal_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(3, 0, ss)

      assert {:error, :temporal_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(7, 0, ss)
    end

    test "accepts LID within capability (n_s=0 means 1 layer, max LID=0)", %{ss: ss} do
      assert :ok = IDSValidator.validate_ids_with_capabilities(0, 0, ss)
    end

    test "rejects LID exceeding capability", %{ss: ss} do
      assert {:error, :spatial_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(0, 1, ss)

      assert {:error, :spatial_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(0, 2, ss)
    end
  end

  describe "validate_ids_with_capabilities/3 - with SS (SVC stream)" do
    setup do
      # SVC: 2 spatial layers (n_s=1), 3 temporal layers per spatial
      ss = %ScalabilityStructure{
        n_s: 1,
        y_flag: false,
        n_g: 6,
        spatial_layers: [
          %{width: 1920, height: 1080, frame_rate: 30},
          %{width: 960, height: 540, frame_rate: 30}
        ],
        pictures: [
          # Spatial 0, temporal 0-2
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: []},
          %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [1]},
          %{temporal_id: 2, spatial_id: 0, reference_count: 1, p_diffs: [1]},
          # Spatial 1, temporal 0-2
          %{temporal_id: 0, spatial_id: 1, reference_count: 1, p_diffs: [3]},
          %{temporal_id: 1, spatial_id: 1, reference_count: 2, p_diffs: [1, 4]},
          %{temporal_id: 2, spatial_id: 1, reference_count: 2, p_diffs: [1, 4]}
        ]
      }

      {:ok, ss: ss}
    end

    test "accepts all valid TID/LID combinations", %{ss: ss} do
      for tid <- 0..2, lid <- 0..1 do
        assert :ok = IDSValidator.validate_ids_with_capabilities(tid, lid, ss)
      end
    end

    test "rejects TID exceeding capability", %{ss: ss} do
      assert {:error, :temporal_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(3, 0, ss)

      assert {:error, :temporal_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(3, 1, ss)
    end

    test "rejects LID exceeding capability (n_s=1 means 2 layers, max LID=1)", %{ss: ss} do
      assert {:error, :spatial_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(0, 2, ss)

      assert {:error, :spatial_id_exceeds_capability} =
               IDSValidator.validate_ids_with_capabilities(0, 3, ss)
    end
  end

  describe "encode_ids_byte/2" do
    test "encodes TID=0, LID=0 correctly" do
      assert 0b00000000 = IDSValidator.encode_ids_byte(0, 0)
    end

    test "encodes TID=7, LID=3 correctly" do
      assert 0b11111000 = IDSValidator.encode_ids_byte(7, 3)
    end

    test "encodes TID=3, LID=1 correctly" do
      assert 0b01101000 = IDSValidator.encode_ids_byte(3, 1)
    end

    test "encodes TID=5, LID=2 correctly" do
      assert 0b10110000 = IDSValidator.encode_ids_byte(5, 2)
    end

    test "always sets reserved bits to 0" do
      for tid <- 0..7, lid <- 0..3 do
        byte = IDSValidator.encode_ids_byte(tid, lid)
        # Check that bits 0-2 are always 0
        assert (byte &&& 0b00000111) == 0
      end
    end
  end

  describe "decode_ids_byte/1" do
    test "decodes TID=0, LID=0 correctly" do
      assert {:ok, 0, 0} = IDSValidator.decode_ids_byte(0b00000000)
    end

    test "decodes TID=7, LID=3 correctly" do
      assert {:ok, 7, 3} = IDSValidator.decode_ids_byte(0b11111000)
    end

    test "decodes TID=3, LID=1 correctly" do
      assert {:ok, 3, 1} = IDSValidator.decode_ids_byte(0b01101000)
    end

    test "decodes TID=5, LID=2 correctly" do
      assert {:ok, 5, 2} = IDSValidator.decode_ids_byte(0b10110000)
    end

    test "rejects byte with reserved bits set" do
      assert {:error, :reserved_kid_bits_set} = IDSValidator.decode_ids_byte(0b01101001)
      assert {:error, :reserved_kid_bits_set} = IDSValidator.decode_ids_byte(0b01101111)
    end

    test "rejects invalid byte format" do
      assert {:error, :invalid_ids_byte} = IDSValidator.decode_ids_byte("invalid")
      assert {:error, :invalid_ids_byte} = IDSValidator.decode_ids_byte(-1)
      assert {:error, :invalid_ids_byte} = IDSValidator.decode_ids_byte(256)
    end
  end

  describe "encode/decode round-trip" do
    test "round-trips all valid TID/LID combinations" do
      for tid <- 0..7, lid <- 0..3 do
        byte = IDSValidator.encode_ids_byte(tid, lid)
        assert {:ok, ^tid, ^lid} = IDSValidator.decode_ids_byte(byte)
      end
    end
  end

  describe "error_message/1" do
    test "returns readable message for :invalid_temporal_id" do
      msg = IDSValidator.error_message({:error, :invalid_temporal_id})
      assert msg == "Temporal ID must be 0-7"
    end

    test "returns readable message for :invalid_spatial_id" do
      msg = IDSValidator.error_message({:error, :invalid_spatial_id})
      assert msg == "Spatial ID must be 0-3"
    end

    test "returns readable message for :reserved_kid_bits_set" do
      msg = IDSValidator.error_message({:error, :reserved_kid_bits_set})
      assert msg == "Reserved KID bits (bits 0-2) in IDS byte must be 0"
    end

    test "returns readable message for :temporal_id_exceeds_capability" do
      msg = IDSValidator.error_message({:error, :temporal_id_exceeds_capability})
      assert msg == "Temporal ID exceeds stream capability (too many temporal layers)"
    end

    test "returns readable message for :spatial_id_exceeds_capability" do
      msg = IDSValidator.error_message({:error, :spatial_id_exceeds_capability})
      assert msg == "Spatial ID exceeds stream capability (too many spatial layers)"
    end

    test "returns readable message for :missing_ids" do
      msg = IDSValidator.error_message({:error, :missing_ids})
      assert msg == "IDS (temporal_id/spatial_id) required when M=1"
    end

    test "returns readable message for :invalid_ids_byte" do
      msg = IDSValidator.error_message({:error, :invalid_ids_byte})
      assert msg == "Invalid IDS byte format"
    end

    test "returns generic message for unknown error" do
      msg = IDSValidator.error_message({:error, :unknown})
      assert msg == "Unknown IDS validation error"
    end
  end
end
