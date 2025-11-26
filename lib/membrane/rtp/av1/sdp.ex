defmodule Membrane.RTP.AV1.SDP do
  @moduledoc """
  Utilities for generating SDP attributes for AV1 RTP streams.

  This module provides functions to generate SDP (Session Description Protocol)
  attributes according to the AV1 RTP payload format specification
  (draft-ietf-avtcore-rtp-av1).

  ## Examples

      iex> Membrane.RTP.AV1.SDP.rtpmap(45)
      "a=rtpmap:45 AV1/90000"

      iex> Membrane.RTP.AV1.SDP.rtpmap(45, profile: 0)
      "a=rtpmap:45 AV1/90000"
  """

  @clock_rate 90_000
  @encoding_name "AV1"

  @typedoc """
  Options for generating SDP attributes.

  - `:profile` - AV1 profile (0=Main, 1=High, 2=Professional)
  - `:level` - AV1 level (e.g., "4.0", "5.1")
  - `:tier` - AV1 tier (0=Main, 1=High)
  """
  @type sdp_opts :: [
          profile: 0..2,
          level: String.t(),
          tier: 0..1
        ]

  @doc """
  Generates an rtpmap attribute line for AV1.

  The rtpmap attribute specifies the payload type, encoding name, and clock rate.
  For AV1, the clock rate is always 90000 Hz as specified in the RTP AV1 payload format.

  ## Parameters

  - `payload_type` - The RTP payload type number (typically 96-127 for dynamic types)
  - `_opts` - Options for future extensibility (currently unused)

  ## Returns

  An rtpmap attribute string in the format: `"a=rtpmap:<payload_type> AV1/90000"`

  ## Examples

      iex> Membrane.RTP.AV1.SDP.rtpmap(45)
      "a=rtpmap:45 AV1/90000"

      iex> Membrane.RTP.AV1.SDP.rtpmap(100)
      "a=rtpmap:100 AV1/90000"

  """
  @spec rtpmap(payload_type :: non_neg_integer(), opts :: sdp_opts()) :: String.t()
  def rtpmap(payload_type, _opts \\ []) do
    "a=rtpmap:#{payload_type} #{@encoding_name}/#{@clock_rate}"
  end

  @doc """
  Generates an fmtp attribute line for AV1 with optional parameters.

  The fmtp (format parameters) attribute provides additional codec-specific
  configuration. For AV1, this can include profile, level, and tier information.

  ## Parameters

  - `payload_type` - The RTP payload type number
  - `opts` - Keyword list of format parameters:
    - `:profile` - AV1 profile (0=Main, 1=High, 2=Professional)
    - `:level` - AV1 level as string (e.g., "4.0", "5.1")
    - `:tier` - AV1 tier (0=Main, 1=High)
    - `:cm` - Congestion management (0 or 1)
    - `:temporal_id` - Temporal layer ID (0-7), will be encoded as `tid`
    - `:spatial_id` - Spatial layer ID (0-3), will be encoded as `lid`

  ## Returns

  An fmtp attribute string, or `nil` if no parameters are provided.

  ## Examples

      iex> Membrane.RTP.AV1.SDP.fmtp(96, profile: 0, level: "4.0", tier: 0)
      "a=fmtp:96 profile=0;level-idx=8;tier=0"

      iex> Membrane.RTP.AV1.SDP.fmtp(96, profile: 1)
      "a=fmtp:96 profile=1"

      iex> Membrane.RTP.AV1.SDP.fmtp(96, [])
      nil

  """
  @spec fmtp(payload_type :: non_neg_integer(), opts :: sdp_opts()) :: String.t() | nil
  def fmtp(payload_type, opts) when is_list(opts) do
    params = build_fmtp_params(opts)

    case params do
      [] -> nil
      params -> "a=fmtp:#{payload_type} #{Enum.join(params, ";")}"
    end
  end

  @doc """
  Generates complete SDP attributes for AV1, including both rtpmap and fmtp.

  This is a convenience function that combines both rtpmap and fmtp generation.

  ## Parameters

  - `payload_type` - The RTP payload type number
  - `opts` - Options for fmtp generation (see `fmtp/2`)

  ## Returns

  A list of SDP attribute strings.

  ## Examples

      iex> Membrane.RTP.AV1.SDP.generate(96)
      ["a=rtpmap:96 AV1/90000"]

      iex> Membrane.RTP.AV1.SDP.generate(96, profile: 0, level: "4.0")
      ["a=rtpmap:96 AV1/90000", "a=fmtp:96 profile=0;level-idx=8"]

  """
  @spec generate(payload_type :: non_neg_integer(), opts :: sdp_opts()) :: [String.t()]
  def generate(payload_type, opts \\ []) do
    rtpmap_line = rtpmap(payload_type, opts)

    case fmtp(payload_type, opts) do
      nil -> [rtpmap_line]
      fmtp_line -> [rtpmap_line, fmtp_line]
    end
  end

  @doc """
  Returns the fixed clock rate for AV1 RTP streams.

  ## Examples

      iex> Membrane.RTP.AV1.SDP.clock_rate()
      90000

  """
  @spec clock_rate() :: pos_integer()
  def clock_rate, do: @clock_rate

  @doc """
  Returns the encoding name for AV1.

  ## Examples

      iex> Membrane.RTP.AV1.SDP.encoding_name()
      "AV1"

  """
  @spec encoding_name() :: String.t()
  def encoding_name, do: @encoding_name

  # Private functions

  # Mapping of AV1 level strings to level-idx values (0-31)
  # Based on AV1 specification Annex A
  @level_idx_map %{
    "2.0" => 0,
    "2.1" => 1,
    "2.2" => 2,
    "2.3" => 3,
    "3.0" => 4,
    "3.1" => 5,
    "3.2" => 6,
    "3.3" => 7,
    "4.0" => 8,
    "4.1" => 9,
    "4.2" => 10,
    "4.3" => 11,
    "5.0" => 12,
    "5.1" => 13,
    "5.2" => 14,
    "5.3" => 15,
    "6.0" => 16,
    "6.1" => 17,
    "6.2" => 18,
    "6.3" => 19,
    "7.0" => 20,
    "7.1" => 21,
    "7.2" => 22,
    "7.3" => 23
  }

  defp build_fmtp_params(opts) do
    []
    |> maybe_add_profile(opts[:profile])
    |> maybe_add_level(opts[:level])
    |> maybe_add_tier(opts[:tier])
    |> maybe_add_cm(opts[:cm])
    |> maybe_add_temporal_id(opts[:temporal_id])
    |> maybe_add_spatial_id(opts[:spatial_id])
  end

  defp maybe_add_profile(params, nil), do: params

  defp maybe_add_profile(params, profile) when profile in 0..2 do
    params ++ ["profile=#{profile}"]
  end

  defp maybe_add_level(params, nil), do: params

  defp maybe_add_level(params, level) when is_binary(level) do
    case Map.get(@level_idx_map, level) do
      nil -> params
      level_idx -> params ++ ["level-idx=#{level_idx}"]
    end
  end

  defp maybe_add_tier(params, nil), do: params

  defp maybe_add_tier(params, tier) when tier in 0..1 do
    params ++ ["tier=#{tier}"]
  end

  defp maybe_add_cm(params, nil), do: params

  defp maybe_add_cm(params, cm) when cm in 0..1 do
    params ++ ["cm=#{cm}"]
  end

  defp maybe_add_temporal_id(params, nil), do: params

  defp maybe_add_temporal_id(params, tid) when tid in 0..7 do
    params ++ ["tid=#{tid}"]
  end

  defp maybe_add_spatial_id(params, nil), do: params

  defp maybe_add_spatial_id(params, lid) when lid in 0..3 do
    params ++ ["lid=#{lid}"]
  end
end
