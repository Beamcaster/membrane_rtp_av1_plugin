defmodule Membrane.RTP.AV1.Format do
  @moduledoc """
  Stream format definition for AV1 RTP streams.

  This module defines the `Membrane.RTP.AV1.Format` stream format struct used for
  capability negotiation between Membrane elements in an AV1 RTP pipeline.

  ## Fields

  - `encoding` - Always `"AV1"` for AV1 streams
  - `clock_rate` - Always `90000` Hz (fixed per AV1 RTP spec)
  - `payload_type` - RTP payload type number (0-127), or nil
  - `profile` - AV1 profile: 0 (Main), 1 (High), 2 (Professional), or nil
  - `level` - AV1 level string (e.g., "2.0", "4.0", "5.1"), or nil
  - `tier` - AV1 tier: 0 (Main), 1 (High), or nil
  - `cm` - Congestion management: 0 or 1, or nil
  - `temporal_id`, `spatial_id` - Layer IDs, or nil
  - `scalability_structure` - Optional `%ScalabilityStructure{}`

  ## Examples

      # Basic AV1 format
      %Membrane.RTP.AV1.Format{
        encoding: "AV1",
        clock_rate: 90000
      }

      # With codec constraints
      %Membrane.RTP.AV1.Format{
        encoding: "AV1",
        clock_rate: 90000,
        profile: 0,
        level: "4.0",
        tier: 0
      }

  """

  alias Membrane.RTP.AV1.{FMTP, SDP, ScalabilityStructure}

  @type t :: %__MODULE__{
          encoding: String.t(),
          clock_rate: pos_integer(),
          payload_type: 0..127 | nil,
          profile: 0..2 | nil,
          level: String.t() | nil,
          tier: 0..1 | nil,
          cm: 0..1 | nil,
          temporal_id: 0..7 | nil,
          spatial_id: 0..3 | nil,
          scalability_structure: ScalabilityStructure.t() | nil
        }

  defstruct encoding: "AV1",
            clock_rate: 90_000,
            payload_type: nil,
            profile: nil,
            level: nil,
            tier: nil,
            cm: nil,
            temporal_id: nil,
            spatial_id: nil,
            scalability_structure: nil

  @doc """
  Creates a new AV1 stream format.

  ## Options

  - `:payload_type` - RTP payload type (0-127)
  - `:profile` - AV1 profile (0-2)
  - `:level` - AV1 level string (e.g., "4.0")
  - `:tier` - AV1 tier (0-1)
  - `:cm` - Congestion management (0-1)
  - `:temporal_id` - Temporal layer ID (0-7)
  - `:spatial_id` - Spatial layer ID (0-3)
  - `:scalability_structure` - Optional `%ScalabilityStructure{}`

  ## Examples

      iex> Membrane.RTP.AV1.Format.new([])
      %Membrane.RTP.AV1.Format{encoding: "AV1", clock_rate: 90000}

      iex> Membrane.RTP.AV1.Format.new(profile: 0, level: "4.0", tier: 0)
      %Membrane.RTP.AV1.Format{encoding: "AV1", clock_rate: 90000, profile: 0, level: "4.0", tier: 0}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      payload_type: Keyword.get(opts, :payload_type),
      profile: Keyword.get(opts, :profile),
      level: Keyword.get(opts, :level),
      tier: Keyword.get(opts, :tier),
      cm: Keyword.get(opts, :cm),
      temporal_id: Keyword.get(opts, :temporal_id),
      spatial_id: Keyword.get(opts, :spatial_id),
      scalability_structure: Keyword.get(opts, :scalability_structure)
    }
  end

  @doc """
  Creates an AV1 stream format from an FMTP struct.

  ## Parameters

  - `fmtp` - `%FMTP{}` struct

  ## Returns

  The format struct with fields populated from the FMTP parameters.
  Level index is converted to level string (e.g., 8 -> "4.0").

  ## Examples

      iex> fmtp = Membrane.RTP.AV1.FMTP.parse_legacy(%{profile: 0, level_idx: 8, tier: 0})
      iex> Membrane.RTP.AV1.Format.from_fmtp(fmtp)
      %Membrane.RTP.AV1.Format{
        encoding: "AV1",
        clock_rate: 90000,
        profile: 0,
        level: "4.0",
        tier: 0
      }

      iex> fmtp = Membrane.RTP.AV1.FMTP.parse_legacy(%{profile: 1, level_idx: 13})
      iex> Membrane.RTP.AV1.Format.from_fmtp(fmtp)
      %Membrane.RTP.AV1.Format{
        encoding: "AV1",
        clock_rate: 90000,
        profile: 1,
        level: "5.1"
      }

  """
  @spec from_fmtp(FMTP.t()) :: t()
  def from_fmtp(%FMTP{} = fmtp) do
    %__MODULE__{
      profile: fmtp.profile,
      level: idx_to_level(fmtp.level_idx),
      tier: fmtp.tier,
      cm: fmtp.cm,
      temporal_id: fmtp.temporal_id,
      spatial_id: fmtp.spatial_id,
      scalability_structure: fmtp.scalability_structure
    }
  end

  @doc """
  Converts an AV1 stream format to an FMTP struct.

  ## Parameters

  - `format` - `%Format{}` struct

  ## Returns

  An `%FMTP{}` struct with fields populated from the format.
  Level string is converted to level index (e.g., "4.0" -> 8).

  """
  @spec to_fmtp(t()) :: FMTP.t()
  def to_fmtp(%__MODULE__{} = format) do
    %FMTP{
      profile: format.profile,
      level_idx: level_to_idx(format.level),
      tier: format.tier,
      cm: format.cm,
      temporal_id: format.temporal_id,
      spatial_id: format.spatial_id,
      scalability_structure: format.scalability_structure
    }
  end

  @doc """
  Parses an AV1 stream format from SDP rtpmap and fmtp lines.

  ## Parameters

  - `rtpmap` - SDP rtpmap line (e.g., "a=rtpmap:96 AV1/90000")
  - `fmtp` - SDP fmtp line (e.g., "a=fmtp:96 profile=0;level-idx=8;tier=0") or nil

  ## Returns

  - `{:ok, format}` - Successfully parsed format
  - `{:error, reason}` - Parsing failed

  """
  @spec from_sdp(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def from_sdp(rtpmap, fmtp \\ nil) do
    with {:ok, pt, encoding, clock_rate} <- parse_rtpmap(rtpmap),
         :ok <- validate_encoding(encoding),
         :ok <- validate_clock_rate(clock_rate),
         {:ok, fmtp_struct} <- parse_fmtp(fmtp) do
      format =
        fmtp_struct
        |> from_fmtp()
        |> Map.put(:payload_type, pt)

      {:ok, format}
    end
  end

  @doc """
  Generates SDP rtpmap and fmtp lines from an AV1 stream format.

  ## Parameters

  - `format` - `%Format{}` struct

  ## Returns

  A list containing:
  - rtpmap line (e.g., "a=rtpmap:96 AV1/90000")
  - fmtp line (e.g., "a=fmtp:96 profile=0;level-idx=8;tier=0"), if parameters present

  """
  @spec to_sdp(t()) :: [String.t()]
  def to_sdp(%__MODULE__{} = format) do
    pt = format.payload_type || 96

    # Build SDP opts
    sdp_opts =
      []
      |> maybe_add_opt(:profile, format.profile)
      |> maybe_add_opt(:level, format.level)
      |> maybe_add_opt(:tier, format.tier)
      |> maybe_add_opt(:cm, format.cm)
      |> maybe_add_opt(:temporal_id, format.temporal_id)
      |> maybe_add_opt(:spatial_id, format.spatial_id)

    SDP.generate(pt, sdp_opts)
  end

  # Private functions

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Level index to level string mapping (matches SDP module)
  defp idx_to_level(nil), do: nil
  defp idx_to_level(0), do: "2.0"
  defp idx_to_level(1), do: "2.1"
  defp idx_to_level(4), do: "3.0"
  defp idx_to_level(5), do: "3.1"
  defp idx_to_level(8), do: "4.0"
  defp idx_to_level(9), do: "4.1"
  defp idx_to_level(12), do: "5.0"
  defp idx_to_level(13), do: "5.1"
  defp idx_to_level(14), do: "5.2"
  defp idx_to_level(15), do: "5.3"
  defp idx_to_level(16), do: "6.0"
  defp idx_to_level(17), do: "6.1"
  defp idx_to_level(18), do: "6.2"
  defp idx_to_level(19), do: "6.3"
  defp idx_to_level(20), do: "7.0"
  defp idx_to_level(21), do: "7.1"
  defp idx_to_level(22), do: "7.2"
  defp idx_to_level(23), do: "7.3"
  defp idx_to_level(_), do: nil

  # Level string to level index mapping (inverse of SDP.level_to_idx)
  defp level_to_idx(nil), do: nil
  defp level_to_idx("2.0"), do: 0
  defp level_to_idx("2.1"), do: 1
  defp level_to_idx("3.0"), do: 4
  defp level_to_idx("3.1"), do: 5
  defp level_to_idx("4.0"), do: 8
  defp level_to_idx("4.1"), do: 9
  defp level_to_idx("5.0"), do: 12
  defp level_to_idx("5.1"), do: 13
  defp level_to_idx("5.2"), do: 14
  defp level_to_idx("5.3"), do: 15
  defp level_to_idx("6.0"), do: 16
  defp level_to_idx("6.1"), do: 17
  defp level_to_idx("6.2"), do: 18
  defp level_to_idx("6.3"), do: 19
  defp level_to_idx("7.0"), do: 20
  defp level_to_idx("7.1"), do: 21
  defp level_to_idx("7.2"), do: 22
  defp level_to_idx("7.3"), do: 23
  defp level_to_idx(_), do: nil

  defp parse_rtpmap(rtpmap) when is_binary(rtpmap) do
    # Parse "a=rtpmap:96 AV1/90000" or "96 AV1/90000"
    rtpmap = String.replace_prefix(rtpmap, "a=rtpmap:", "")

    case String.split(rtpmap, " ", parts: 2) do
      [pt_str, codec_info] ->
        with {pt, ""} <- Integer.parse(pt_str),
             [encoding, clock_rate_str] <- String.split(codec_info, "/"),
             {clock_rate, ""} <- Integer.parse(clock_rate_str) do
          {:ok, pt, encoding, clock_rate}
        else
          _ -> {:error, "invalid rtpmap format"}
        end

      _ ->
        {:error, "invalid rtpmap format"}
    end
  end

  defp validate_encoding("AV1"), do: :ok
  defp validate_encoding(_), do: {:error, "encoding must be AV1"}

  defp validate_clock_rate(90000), do: :ok
  defp validate_clock_rate(_), do: {:error, "clock rate must be 90000"}

  defp parse_fmtp(nil), do: {:ok, %FMTP{}}

  defp parse_fmtp(fmtp) when is_binary(fmtp) do
    # Parse "a=fmtp:96 profile=0;level-idx=8" -> "profile=0;level-idx=8"
    fmtp_value = String.replace(fmtp, ~r/^a=fmtp:\d+\s+/, "")
    FMTP.parse(fmtp_value)
  end
end
