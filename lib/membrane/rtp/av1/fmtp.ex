defmodule Membrane.RTP.AV1.FMTP do
  @moduledoc """
  SDP fmtp (format parameters) parsing and validation for AV1 RTP.

  This module handles parsing of SDP fmtp attributes according to the AV1 RTP
  payload format specification (draft-ietf-avtcore-rtp-av1). It supports:

  - Standard codec parameters: profile, level-idx, tier
  - Layer parameters: cm (congestion management), tid (temporal ID), lid (spatial ID)
  - Scalability structure: ss-data (hex-encoded)

  ## Examples

      iex> Membrane.RTP.AV1.FMTP.parse("profile=0;level-idx=8;tier=0")
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, level_idx: 8, tier: 0}}

      iex> Membrane.RTP.AV1.FMTP.parse("profile=0;cm=1;tid=2")
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, cm: 1, temporal_id: 2}}

      iex> Membrane.RTP.AV1.FMTP.parse_map(%{"profile" => "0", "level-idx" => "8"})
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, level_idx: 8}}

  """
  alias Membrane.RTP.AV1.ScalabilityStructure

  @type profile :: 0..2
  @type level_idx :: 0..31
  @type tier :: 0..1

  @type t :: %__MODULE__{
          profile: profile() | nil,
          level_idx: level_idx() | nil,
          tier: tier() | nil,
          cm: 0 | 1 | nil,
          temporal_id: 0..7 | nil,
          spatial_id: 0..3 | nil,
          scalability_structure: ScalabilityStructure.t() | nil
        }

  defstruct profile: nil,
            level_idx: nil,
            tier: nil,
            cm: nil,
            temporal_id: nil,
            spatial_id: nil,
            scalability_structure: nil

  @doc """
  Parse an fmtp attribute (string or map) into a typed struct.

  For string input, the format should be: "param1=value1;param2=value2;..."
  For map input, both string and atom keys are supported.

  ## Parameters

  - `fmtp_input` - Either a string (SDP fmtp attribute value) or a map of parameters

  ## Returns

  - `{:ok, %FMTP{}}` - Successfully parsed parameters
  - `{:error, reason}` - Parsing or validation failed

  ## Examples

      iex> Membrane.RTP.AV1.FMTP.parse("profile=0;level-idx=8")
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, level_idx: 8}}

      iex> Membrane.RTP.AV1.FMTP.parse(%{profile: 0, tier: 0})
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, tier: 0}}

      iex> Membrane.RTP.AV1.FMTP.parse("cm=1;tid=2;lid=1")
      {:ok, %Membrane.RTP.AV1.FMTP{cm: 1, temporal_id: 2, spatial_id: 1}}

      iex> Membrane.RTP.AV1.FMTP.parse("profile=5")
      {:error, "Invalid profile: 5 (must be 0-2)"}

  """
  @spec parse(String.t() | map()) :: {:ok, t()} | {:error, String.t()}
  def parse(fmtp_input)

  def parse(fmtp_string) when is_binary(fmtp_string) do
    fmtp_string
    |> String.split(";", trim: true)
    |> Enum.reduce({:ok, %{}}, fn
      _param, {:error, _} = error ->
        error

      param, {:ok, acc} ->
        case parse_param(param) do
          {:ok, key, value} -> {:ok, Map.put(acc, key, value)}
          {:error, _} = error -> error
        end
    end)
    |> case do
      {:ok, params_map} -> parse_map(params_map)
      {:error, _} = error -> error
    end
  end

  def parse(fmtp_map) when is_map(fmtp_map) do
    parse_map(fmtp_map)
  end

  @doc """
  Parse a map of fmtp parameters into a typed struct with validation.

  Supports both string and atom keys. Parameter names are normalized:
  - "profile-id" or "profile" -> :profile
  - "level-idx" -> :level_idx
  - "tid" or "temporal_id" -> :temporal_id
  - "lid" or "spatial_id" -> :spatial_id

  ## Parameters

  - `params_map` - Map of parameter names to values (strings or integers)

  ## Returns

  - `{:ok, %FMTP{}}` - Successfully parsed and validated parameters
  - `{:error, reason}` - Validation failed

  ## Examples

      iex> Membrane.RTP.AV1.FMTP.parse_map(%{"profile" => "0", "level-idx" => "8"})
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, level_idx: 8}}

      iex> Membrane.RTP.AV1.FMTP.parse_map(%{profile: 0, tier: 0})
      {:ok, %Membrane.RTP.AV1.FMTP{profile: 0, tier: 0}}

  """
  @spec parse_map(map()) :: {:ok, t()} | {:error, String.t()}
  def parse_map(params) when is_map(params) do
    with {:ok, profile} <- parse_profile(params),
         {:ok, level_idx} <- parse_level_idx(params),
         {:ok, tier} <- parse_tier(params),
         {:ok, cm} <- parse_cm(params),
         {:ok, temporal_id} <- parse_temporal_id(params),
         {:ok, spatial_id} <- parse_spatial_id(params),
         {:ok, ss} <- parse_scalability_structure(params),
         :ok <- validate_param_combinations(profile, level_idx, tier, cm, temporal_id, spatial_id) do
      {:ok,
       %__MODULE__{
         profile: profile,
         level_idx: level_idx,
         tier: tier,
         cm: cm,
         temporal_id: temporal_id,
         spatial_id: spatial_id,
         scalability_structure: ss
       }}
    end
  end

  @doc """
  Parse a map of fmtp parameters (legacy version, returns struct directly).

  This is the legacy API that returns a struct with nil fields for invalid values.
  For new code, prefer `parse/1` or `parse_map/1` which return `{:ok, result}` or `{:error, reason}`.

  ## Examples

      iex> params = %{"cm" => "1", "tid" => "2"}
      iex> fmtp = Membrane.RTP.AV1.FMTP.parse_legacy(params)
      iex> fmtp.cm
      1
      iex> fmtp.temporal_id
      2

  """
  @spec parse_legacy(map()) :: t()
  def parse_legacy(params) when is_map(params) do
    case parse_map(params) do
      {:ok, fmtp} -> fmtp
      {:error, _} -> %__MODULE__{}
    end
  end

  defp parse_param(param_string) do
    case String.split(param_string, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)
        {:ok, normalize_key(key), value}

      _ ->
        {:error, "Invalid parameter format: #{param_string}"}
    end
  end

  defp normalize_key("profile-id"), do: :profile
  defp normalize_key("profile"), do: :profile
  defp normalize_key("level-idx"), do: :level_idx
  defp normalize_key("tier"), do: :tier
  defp normalize_key("cm"), do: :cm
  defp normalize_key("tid"), do: :tid
  defp normalize_key("lid"), do: :lid
  defp normalize_key("temporal_id"), do: :temporal_id
  defp normalize_key("spatial_id"), do: :spatial_id
  defp normalize_key("ss-data"), do: :ss_data
  defp normalize_key("ss_data"), do: :ss_data
  defp normalize_key(key), do: String.to_atom(key)

  defp get_int(params, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) || Map.get(params, to_string(key)) do
        nil ->
          nil

        "" ->
          nil

        v when is_integer(v) ->
          v

        v when is_binary(v) ->
          case Integer.parse(v) do
            {i, ""} -> i
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_profile(params) do
    case get_int(params, [:profile, "profile", "profile-id", "profile_id"]) do
      nil -> {:ok, nil}
      p when p in 0..2 -> {:ok, p}
      p -> {:error, "Invalid profile: #{p} (must be 0-2)"}
    end
  end

  defp parse_level_idx(params) do
    case get_int(params, [:level_idx, "level-idx", "level_idx"]) do
      nil -> {:ok, nil}
      l when l in 0..31 -> {:ok, l}
      l -> {:error, "Invalid level-idx: #{l} (must be 0-31)"}
    end
  end

  defp parse_tier(params) do
    case get_int(params, [:tier, "tier"]) do
      nil -> {:ok, nil}
      t when t in 0..1 -> {:ok, t}
      t -> {:error, "Invalid tier: #{t} (must be 0-1)"}
    end
  end

  defp parse_cm(params) do
    case get_int(params, [:cm, "cm"]) do
      nil -> {:ok, nil}
      cm when cm in 0..1 -> {:ok, cm}
      cm -> {:error, "Invalid cm: #{cm} (must be 0-1)"}
    end
  end

  defp parse_temporal_id(params) do
    case get_int(params, [:tid, "tid", :temporal_id, "temporal_id"]) do
      nil -> {:ok, nil}
      tid when tid in 0..7 -> {:ok, tid}
      tid -> {:error, "Invalid temporal_id: #{tid} (must be 0-7)"}
    end
  end

  defp parse_spatial_id(params) do
    case get_int(params, [:lid, "lid", :spatial_id, "spatial_id"]) do
      nil -> {:ok, nil}
      lid when lid in 0..3 -> {:ok, lid}
      lid -> {:error, "Invalid spatial_id: #{lid} (must be 0-3)"}
    end
  end

  defp parse_scalability_structure(params) do
    case Map.get(params, :ss) || Map.get(params, "ss") do
      %ScalabilityStructure{} = ss ->
        {:ok, ss}

      nil ->
        parse_ss_data(params)

      _ ->
        {:error, "Invalid scalability structure format"}
    end
  end

  defp parse_ss_data(params) do
    case Map.get(params, :ss_data) || Map.get(params, "ss-data") || Map.get(params, "ss_data") do
      nil ->
        {:ok, nil}

      hex_string when is_binary(hex_string) ->
        case Base.decode16(hex_string, case: :mixed) do
          {:ok, binary} ->
            case ScalabilityStructure.decode(binary) do
              {:ok, ss, _rest} -> {:ok, ss}
              {:error, reason} -> {:error, "Invalid ss-data: #{reason}"}
            end

          :error ->
            {:error, "Invalid ss-data hex encoding"}
        end

      _ ->
        {:error, "Invalid ss-data format (must be hex string)"}
    end
  end

  defp validate_param_combinations(profile, _level_idx, tier, _cm, _tid, _lid) do
    cond do
      profile == 0 and tier == 1 ->
        {:error, "Profile 0 (Main) only supports tier 0"}

      true ->
        :ok
    end
  end
end
