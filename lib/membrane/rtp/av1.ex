defmodule Membrane.RTP.AV1 do
  @moduledoc """
  AV1 RTP payload format constants and utilities.

  This module provides constants and utilities for AV1 RTP streams:
  - Encoding name: `:AV1`
  - Clock rate: `90000` Hz (fixed per AV1 RTP spec)
  - Conversion functions between format and FMTP

  ## Main Components

  - `Membrane.RTP.AV1.Depayloader` - Depayloads AV1 from RTP packets
  - `Membrane.RTP.AV1.FMTP` - SDP fmtp parsing
  - `Membrane.RTP.AV1.SDP` - SDP generation
  - `Membrane.AV1` - Stream format for AV1 (from membrane_av1_format package)

  ## Example Pipeline

      child(:rtp_parser, Membrane.RTP.Parser)
      |> child(:depayloader, Membrane.RTP.AV1.Depayloader)
      |> child(:decoder, Membrane.AV1.Decoder)
      |> child(:sink, YourVideoSink)
  """

  alias Membrane.AV1
  alias Membrane.RTP.AV1.{FMTP, SDP}

  @encoding_name :AV1
  @clock_rate 90_000

  @doc """
  Returns the registered encoding name for AV1.

  ## Examples

      iex> Membrane.RTP.AV1.encoding_name()
      :AV1

  """
  @spec encoding_name() :: atom()
  def encoding_name, do: @encoding_name

  @doc """
  Returns the clock rate for AV1 RTP streams.

  ## Examples

      iex> Membrane.RTP.AV1.clock_rate()
      90000

  """
  @spec clock_rate() :: pos_integer()
  def clock_rate, do: @clock_rate

  @doc """
  Creates an AV1 stream format from an FMTP struct.

  ## Parameters

  - `fmtp` - `%FMTP{}` struct

  ## Returns

  The format struct with fields populated from the FMTP parameters.
  Level index is converted to level string (e.g., 8 -> "4.0").

  ## Examples

      iex> fmtp = Membrane.RTP.AV1.FMTP.parse_legacy(%{profile: 0, level_idx: 8, tier: 0})
      iex> Membrane.RTP.AV1.from_fmtp(fmtp)
      %Membrane.AV1{profile: 0, level: "4.0", tier: 0}

  """
  @spec from_fmtp(FMTP.t()) :: AV1.t()
  def from_fmtp(%FMTP{} = fmtp) do
    %AV1{
      profile: fmtp.profile,
      level: idx_to_level(fmtp.level_idx),
      tier: fmtp.tier
    }
  end

  @doc """
  Converts an AV1 stream format to an FMTP struct.

  ## Parameters

  - `format` - `%Membrane.AV1{}` struct

  ## Returns

  An `%FMTP{}` struct with fields populated from the format.
  Level string is converted to level index (e.g., "4.0" -> 8).
  """
  @spec to_fmtp(AV1.t()) :: FMTP.t()
  def to_fmtp(%AV1{} = format) do
    %FMTP{
      profile: format.profile,
      level_idx: level_to_idx(format.level),
      tier: format.tier
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
  @spec from_sdp(String.t(), String.t() | nil) :: {:ok, AV1.t()} | {:error, String.t()}
  def from_sdp(rtpmap, fmtp \\ nil) do
    with {:ok, _pt, encoding, clock_rate} <- parse_rtpmap(rtpmap),
         :ok <- validate_encoding(encoding),
         :ok <- validate_clock_rate(clock_rate),
         {:ok, fmtp_struct} <- parse_fmtp(fmtp) do
      format = from_fmtp(fmtp_struct)
      {:ok, format}
    end
  end

  @doc """
  Generates SDP rtpmap and fmtp lines from an AV1 stream format.

  ## Parameters

  - `format` - `%Membrane.AV1{}` struct
  - `payload_type` - RTP payload type number (default: 96)

  ## Returns

  A list containing:
  - rtpmap line (e.g., "a=rtpmap:96 AV1/90000")
  - fmtp line (e.g., "a=fmtp:96 profile=0;level-idx=8;tier=0"), if parameters present
  """
  @spec to_sdp(AV1.t(), non_neg_integer()) :: [String.t()]
  def to_sdp(%AV1{} = format, payload_type \\ 96) do
    sdp_opts =
      []
      |> maybe_add_opt(:profile, format.profile)
      |> maybe_add_opt(:level, format.level)
      |> maybe_add_opt(:tier, format.tier)

    SDP.generate(payload_type, sdp_opts)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
    fmtp_value = String.replace(fmtp, ~r/^a=fmtp:\d+\s+/, "")
    FMTP.parse(fmtp_value)
  end
end
