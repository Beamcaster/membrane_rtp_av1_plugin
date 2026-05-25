defmodule Membrane.RTP.AV1.ScalabilityStructurePropertyTest do
  @moduledoc """
  Property-based tests for `Membrane.RTP.AV1.ScalabilityStructure`.

  NOTE: this module models a VP9-style RTP scalability structure
  (`N_S` / `Y` / `N_G` / `P_DIFF`). RFC 9628 does not define such a block for
  AV1 — AV1 carries spatial/temporal layering through the OBU extension header
  and the scalability metadata OBU. These properties therefore assert only the
  module's internal encode/decode consistency, not RFC conformance.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Membrane.RTP.AV1.ScalabilityStructure, as: SS
  alias Membrane.RTP.AV1.Test.AV1Generators, as: Gen

  @moduletag :property

  property "encode then decode recovers the structure" do
    check all(ss <- Gen.scalability_struct()) do
      assert {:ok, binary} = SS.encode(ss)
      assert {:ok, decoded, <<>>} = SS.decode(binary)
      assert decoded == ss
    end
  end

  property "decode preserves trailing data after the structure" do
    check all(
            ss <- Gen.scalability_struct(),
            trailing <- StreamData.binary(max_length: 60)
          ) do
      assert {:ok, binary} = SS.encode(ss)
      assert {:ok, decoded, ^trailing} = SS.decode(binary <> trailing)
      assert decoded == ss
    end
  end

  property "simple/3 structures round-trip" do
    check all(
            width <- StreamData.integer(1..65_535),
            height <- StreamData.integer(1..65_535),
            frame_rate <- StreamData.integer(1..240),
            temporal_layers <- StreamData.integer(1..8)
          ) do
      ss = SS.simple(width, height, frame_rate: frame_rate, temporal_layers: temporal_layers)

      assert {:ok, binary} = SS.encode(ss)
      assert {:ok, decoded, <<>>} = SS.decode(binary)
      assert decoded == ss
    end
  end

  property "svc/2 structures round-trip" do
    check all(
            resolutions <- StreamData.list_of(resolution(), min_length: 1, max_length: 4),
            temporal_layers <- StreamData.integer(1..8)
          ) do
      ss = SS.svc(resolutions, temporal_layers)

      assert {:ok, binary} = SS.encode(ss)
      assert {:ok, decoded, <<>>} = SS.decode(binary)
      assert decoded == ss
    end
  end

  property "encode rejects an out-of-range n_s" do
    check all(ss <- Gen.invalid_n_s_struct()) do
      assert {:error, :invalid_n_s} = SS.encode(ss)
    end
  end

  property "encode rejects an out-of-range n_g" do
    check all(ss <- Gen.invalid_n_g_struct()) do
      assert {:error, :invalid_n_g} = SS.encode(ss)
    end
  end

  property "encode rejects a spatial-layer count that does not match n_s" do
    check all(ss <- Gen.layer_mismatch_struct()) do
      assert {:error, :spatial_layer_count_mismatch} = SS.encode(ss)
    end
  end

  property "encode rejects a picture count that does not match n_g" do
    check all(ss <- Gen.picture_mismatch_struct()) do
      assert {:error, :picture_count_mismatch} = SS.encode(ss)
    end
  end

  property "decode rejects a binary larger than the maximum structure size" do
    check all(binary <- Gen.oversized_ss_binary()) do
      assert {:error, :ss_too_large} = SS.decode(binary)
    end
  end

  property "decode never raises on arbitrary input" do
    check all(binary <- StreamData.binary(max_length: 255)) do
      case SS.decode(binary) do
        {:ok, %SS{}, rest} when is_binary(rest) -> :ok
        {:error, reason} when is_atom(reason) -> :ok
      end
    end
  end

  property "simple/3 caps temporal layers at the 3-bit temporal_id limit" do
    check all(
            width <- StreamData.integer(1..65_535),
            height <- StreamData.integer(1..65_535),
            temporal_layers <- StreamData.integer(9..15)
          ) do
      ss = SS.simple(width, height, temporal_layers: temporal_layers)

      assert {:ok, binary} = SS.encode(ss)
      assert {:ok, decoded, <<>>} = SS.decode(binary)
      assert decoded == ss
    end
  end

  defp resolution do
    StreamData.tuple({StreamData.integer(1..65_535), StreamData.integer(1..65_535)})
  end
end
