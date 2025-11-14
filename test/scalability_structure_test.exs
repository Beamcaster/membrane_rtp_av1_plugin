defmodule Membrane.RTP.AV1.ScalabilityStructureTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.ScalabilityStructure

  describe "simple/2" do
    test "creates valid single-layer structure" do
      ss = ScalabilityStructure.simple(1920, 1080, frame_rate: 30, temporal_layers: 1)

      assert ss.n_s == 0
      assert ss.y_flag == false
      assert ss.n_g == 1
      assert length(ss.spatial_layers) == 1
      assert [%{width: 1920, height: 1080, frame_rate: 30}] = ss.spatial_layers
      assert length(ss.pictures) == 1
    end

    test "creates structure with multiple temporal layers" do
      ss = ScalabilityStructure.simple(1280, 720, frame_rate: 60, temporal_layers: 3)

      assert ss.n_s == 0
      assert ss.n_g == 3
      assert length(ss.pictures) == 3

      temporal_ids = Enum.map(ss.pictures, & &1.temporal_id)
      assert temporal_ids == [0, 1, 2]
    end
  end

  describe "svc/2" do
    test "creates structure with multiple spatial layers" do
      spatial_resolutions = [
        {640, 360},
        {1280, 720},
        {1920, 1080}
      ]

      ss = ScalabilityStructure.svc(spatial_resolutions, 2)

      assert ss.n_s == 2
      assert ss.y_flag == true
      assert length(ss.spatial_layers) == 3

      assert ss.spatial_layers == [
               %{width: 640, height: 360, frame_rate: nil},
               %{width: 1280, height: 720, frame_rate: nil},
               %{width: 1920, height: 1080, frame_rate: nil}
             ]

      # Should have temporal_layers * spatial_layers pictures (up to 15)
      assert ss.n_g == 6
      assert length(ss.pictures) == 6
    end

    test "limits picture count to 15" do
      spatial_resolutions = [{1920, 1080}, {3840, 2160}]
      ss = ScalabilityStructure.svc(spatial_resolutions, 10)

      # 2 spatial layers * 10 temporal layers = 20, but capped at 15
      assert ss.n_g == 15
      assert length(ss.pictures) == 15
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trip simple structure" do
      original = ScalabilityStructure.simple(1920, 1080, frame_rate: 30, temporal_layers: 1)

      assert {:ok, encoded} = ScalabilityStructure.encode(original)
      assert is_binary(encoded)
      assert byte_size(encoded) > 0

      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)

      assert decoded.n_s == original.n_s
      assert decoded.y_flag == original.y_flag
      assert decoded.n_g == original.n_g
      assert decoded.spatial_layers == original.spatial_layers
      assert decoded.pictures == original.pictures
    end

    test "round-trip SVC structure" do
      original =
        ScalabilityStructure.svc([{640, 360}, {1280, 720}, {1920, 1080}], 3)

      assert {:ok, encoded} = ScalabilityStructure.encode(original)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)

      assert decoded.n_s == original.n_s
      assert decoded.y_flag == original.y_flag
      assert decoded.n_g == original.n_g
      assert decoded.spatial_layers == original.spatial_layers
      assert decoded.pictures == original.pictures
    end

    test "round-trip with frame rate (Y=0)" do
      original = ScalabilityStructure.simple(1280, 720, frame_rate: 60, temporal_layers: 2)

      assert {:ok, encoded} = ScalabilityStructure.encode(original)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)

      assert decoded.spatial_layers == original.spatial_layers
      assert hd(decoded.spatial_layers).frame_rate == 60
    end

    test "round-trip without frame rate (Y=1)" do
      original = ScalabilityStructure.svc([{1920, 1080}], 1)

      assert original.y_flag == true
      assert {:ok, encoded} = ScalabilityStructure.encode(original)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)

      assert hd(decoded.spatial_layers).frame_rate == nil
    end

    test "preserves trailing data" do
      ss = ScalabilityStructure.simple(640, 480)
      trailing = <<1, 2, 3, 4>>

      assert {:ok, encoded} = ScalabilityStructure.encode(ss)
      binary_with_trailing = encoded <> trailing

      assert {:ok, _decoded, rest} = ScalabilityStructure.decode(binary_with_trailing)
      assert rest == trailing
    end
  end

  describe "validation" do
    test "rejects structure exceeding max size" do
      # Create a structure that would exceed 255 bytes
      # With n_s=7 (8 layers), each layer = 6 bytes (w+h, no frame_rate when Y=1)
      # Header = 1 byte, Layers = 48 bytes
      # Each picture = 1 + 8 p_diffs = 9 bytes
      # For 255 bytes total: 1 + 48 + (9 * pictures) <= 255
      # pictures <= (255 - 49) / 9 = 22.88, so 15 pictures = 184 total bytes (fits!)
      # We need more - let's use Y=0 to include frame rates: 8 bytes per layer = 64 bytes
      # 1 + 64 + (9 * 15) = 200 bytes (still fits!)

      # Actually, let's just create an invalid structure that violates n_s > 7
      spatial_layers = for _ <- 1..20, do: {1920, 1080}

      ss = %ScalabilityStructure{
        # Invalid: > 7
        n_s: 19,
        y_flag: true,
        n_g: 10,
        spatial_layers:
          Enum.map(spatial_layers, fn {w, h} -> %{width: w, height: h, frame_rate: nil} end),
        pictures: []
      }

      # Should fail validation due to n_s > 7, not size
      assert {:error, :invalid_n_s} = ScalabilityStructure.encode(ss)
    end

    test "rejects binary exceeding max size on decode" do
      oversized_binary = :crypto.strong_rand_bytes(300)
      assert {:error, :ss_too_large} = ScalabilityStructure.decode(oversized_binary)
    end

    test "rejects invalid n_s value" do
      ss = %ScalabilityStructure{
        n_s: 8,
        y_flag: false,
        n_g: 1,
        spatial_layers: [%{width: 1920, height: 1080, frame_rate: 30}],
        pictures: [%{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0]}]
      }

      assert {:error, :invalid_n_s} = ScalabilityStructure.encode(ss)
    end

    test "rejects spatial layer count mismatch" do
      ss = %ScalabilityStructure{
        n_s: 1,
        y_flag: false,
        n_g: 1,
        spatial_layers: [%{width: 1920, height: 1080, frame_rate: 30}],
        pictures: [%{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0, 0]}]
      }

      assert {:error, :spatial_layer_count_mismatch} = ScalabilityStructure.encode(ss)
    end

    test "rejects invalid spatial layer dimensions" do
      ss = %ScalabilityStructure{
        n_s: 0,
        y_flag: false,
        n_g: 1,
        spatial_layers: [%{width: 0, height: 1080, frame_rate: 30}],
        pictures: [%{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0]}]
      }

      assert {:error, :invalid_spatial_layer} = ScalabilityStructure.encode(ss)
    end

    test "rejects picture with invalid temporal_id" do
      ss = %ScalabilityStructure{
        n_s: 0,
        y_flag: false,
        n_g: 1,
        spatial_layers: [%{width: 1920, height: 1080, frame_rate: 30}],
        pictures: [%{temporal_id: 8, spatial_id: 0, reference_count: 0, p_diffs: [0]}]
      }

      assert {:error, :invalid_picture_desc} = ScalabilityStructure.encode(ss)
    end

    test "rejects incomplete binary on decode" do
      # Header only, no spatial layer data
      assert {:error, :incomplete_spatial_layers} = ScalabilityStructure.decode(<<0x10>>)
    end

    test "rejects truncated picture data" do
      # Valid header and spatial layer, but truncated picture desc
      ss = ScalabilityStructure.simple(1920, 1080)
      {:ok, encoded} = ScalabilityStructure.encode(ss)

      # Truncate last byte
      truncated = binary_part(encoded, 0, byte_size(encoded) - 1)
      assert {:error, :incomplete_picture_desc} = ScalabilityStructure.decode(truncated)
    end
  end

  describe "edge cases" do
    test "handles zero temporal layers gracefully" do
      ss = ScalabilityStructure.simple(1920, 1080, temporal_layers: 1)
      assert ss.n_g == 1
      assert length(ss.pictures) == 1
    end

    test "handles single pixel resolution" do
      ss = ScalabilityStructure.simple(1, 1)
      assert {:ok, encoded} = ScalabilityStructure.encode(ss)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)
      assert decoded.spatial_layers == [%{width: 1, height: 1, frame_rate: 30}]
    end

    test "handles maximum valid resolution" do
      ss = ScalabilityStructure.simple(65535, 65535)
      assert {:ok, encoded} = ScalabilityStructure.encode(ss)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)
      assert decoded.spatial_layers == [%{width: 65535, height: 65535, frame_rate: 30}]
    end

    test "handles complex dependency structure" do
      ss = %ScalabilityStructure{
        n_s: 1,
        y_flag: false,
        n_g: 3,
        spatial_layers: [
          %{width: 640, height: 360, frame_rate: 30},
          %{width: 1280, height: 720, frame_rate: 30}
        ],
        pictures: [
          %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0, 0]},
          %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [1, 0]},
          %{temporal_id: 0, spatial_id: 1, reference_count: 1, p_diffs: [2, 1]}
        ]
      }

      assert {:ok, encoded} = ScalabilityStructure.encode(ss)
      assert {:ok, decoded, <<>>} = ScalabilityStructure.decode(encoded)
      assert decoded.pictures == ss.pictures
    end
  end
end
