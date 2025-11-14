defmodule Membrane.RTP.AV1.IDSValidator do
  @moduledoc """
  Validates IDS (TID/LID/KID) fields against stream capabilities.

  IDS byte format (when M=1 in payload descriptor):
  - Byte 1: T T T L L R R R
    - T (bits 7-5): Temporal ID (TID), 3 bits, range 0-7
    - L (bits 4-3): Spatial ID (LID), 2 bits, range 0-3
    - R (bits 2-0): Reserved (KID), must be 0

  Validation includes:
  1. Basic field validation (TID 0-7, LID 0-3, reserved bits = 0)
  2. Capability validation when ScalabilityStructure is present:
     - TID must be < Y (number of temporal layers)
     - LID must be <= N_S (number of spatial layers)
  """

  alias Membrane.RTP.AV1.ScalabilityStructure

  @type validation_error ::
          {:error,
           :invalid_temporal_id
           | :invalid_spatial_id
           | :reserved_kid_bits_set
           | :temporal_id_exceeds_capability
           | :spatial_id_exceeds_capability
           | :missing_ids
           | :invalid_ids_byte}

  @doc """
  Validates IDS byte (byte 1 when M=1).

  Checks:
  - Reserved bits (KID, bits 0-2) must be 0
  - Temporal ID (TID) in range 0-7
  - Spatial ID (LID) in range 0-3

  Returns :ok or {:error, reason}.

  ## Examples

      # Valid: TID=3, LID=1, reserved=0
      iex> IDSValidator.validate_ids_byte(0b01101000)
      :ok
      
      # Invalid: reserved bits set
      iex> IDSValidator.validate_ids_byte(0b01101111)
      {:error, :reserved_kid_bits_set}
  """
  @spec validate_ids_byte(byte()) :: :ok | validation_error()
  def validate_ids_byte(b1) when is_integer(b1) and b1 >= 0 and b1 <= 255 do
    import Bitwise

    t = (b1 &&& 0b1110_0000) >>> 5
    l = (b1 &&& 0b0001_1000) >>> 3
    reserved = b1 &&& 0b0000_0111

    cond do
      reserved != 0 ->
        {:error, :reserved_kid_bits_set}

      t > 7 ->
        {:error, :invalid_temporal_id}

      l > 3 ->
        {:error, :invalid_spatial_id}

      true ->
        :ok
    end
  end

  def validate_ids_byte(_), do: {:error, :invalid_ids_byte}

  @doc """
  Validates temporal_id and spatial_id values (basic range check).

  Returns :ok or {:error, reason}.

  ## Examples

      iex> IDSValidator.validate_ids(3, 1)
      :ok
      
      iex> IDSValidator.validate_ids(8, 1)
      {:error, :invalid_temporal_id}
      
      iex> IDSValidator.validate_ids(3, 4)
      {:error, :invalid_spatial_id}
  """
  @spec validate_ids(non_neg_integer() | nil, non_neg_integer() | nil) ::
          :ok | validation_error()
  def validate_ids(temporal_id, spatial_id) do
    with :ok <- validate_temporal_id(temporal_id),
         :ok <- validate_spatial_id(spatial_id) do
      :ok
    end
  end

  @doc """
  Validates IDS values against ScalabilityStructure capabilities.

  When a ScalabilityStructure is present (Z=1), the temporal_id and spatial_id
  must be within the declared capabilities:
  - temporal_id must be < Y (number of temporal layers, stored as Y value + base)
  - spatial_id must be <= N_S (number of spatial layers - 1)

  Returns :ok or {:error, reason}.

  ## Examples

      # Valid: TID=2, LID=1 within SS capabilities (3 temporal, 2 spatial)
      iex> ss = %ScalabilityStructure{n_s: 1, y_flag: false, n_g: 0, 
      ...>   spatial_layers: [
      ...>     %{width: 1920, height: 1080, frame_rate: 30},
      ...>     %{width: 960, height: 540, frame_rate: 30}
      ...>   ],
      ...>   pictures: []}
      iex> IDSValidator.validate_ids_with_capabilities(2, 1, ss)
      :ok
      
      # Invalid: TID=5 exceeds SS capability (only 3 temporal layers)
      iex> ss = %ScalabilityStructure{n_s: 0, y_flag: false, n_g: 1,
      ...>   spatial_layers: [%{width: 1920, height: 1080, frame_rate: 30}],
      ...>   pictures: [%{temporal_id: 2, spatial_id: 0, reference_count: 0, p_diffs: []}]}
      iex> IDSValidator.validate_ids_with_capabilities(5, 0, ss)
      {:error, :temporal_id_exceeds_capability}
  """
  @spec validate_ids_with_capabilities(
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          ScalabilityStructure.t() | nil
        ) :: :ok | validation_error()
  def validate_ids_with_capabilities(temporal_id, spatial_id, nil) do
    # No SS present, just do basic validation
    validate_ids(temporal_id, spatial_id)
  end

  def validate_ids_with_capabilities(temporal_id, spatial_id, %ScalabilityStructure{} = ss) do
    with :ok <- validate_ids(temporal_id, spatial_id),
         :ok <- validate_temporal_id_capability(temporal_id, ss),
         :ok <- validate_spatial_id_capability(spatial_id, ss) do
      :ok
    end
  end

  @doc """
  Encodes temporal_id and spatial_id into IDS byte.

  Returns encoded byte with format: T T T L L 0 0 0
  Reserved bits (KID) are always 0.

  ## Examples

      iex> IDSValidator.encode_ids_byte(3, 1)
      0b01101000
      
      iex> IDSValidator.encode_ids_byte(7, 3)
      0b11111000
      
      iex> IDSValidator.encode_ids_byte(0, 0)
      0b00000000
  """
  @spec encode_ids_byte(0..7, 0..3) :: byte()
  def encode_ids_byte(temporal_id, spatial_id)
      when is_integer(temporal_id) and temporal_id >= 0 and temporal_id <= 7 and
             is_integer(spatial_id) and spatial_id >= 0 and spatial_id <= 3 do
    import Bitwise
    temporal_id <<< 5 ||| spatial_id <<< 3
  end

  @doc """
  Decodes IDS byte into {temporal_id, spatial_id}.

  Returns {:ok, temporal_id, spatial_id} or {:error, reason}.

  ## Examples

      iex> IDSValidator.decode_ids_byte(0b01101000)
      {:ok, 3, 1}
      
      iex> IDSValidator.decode_ids_byte(0b11111000)
      {:ok, 7, 3}
      
      iex> IDSValidator.decode_ids_byte(0b00000111)
      {:error, :reserved_kid_bits_set}
  """
  @spec decode_ids_byte(byte()) ::
          {:ok, 0..7, 0..3} | validation_error()
  def decode_ids_byte(b1) when is_integer(b1) and b1 >= 0 and b1 <= 255 do
    case validate_ids_byte(b1) do
      :ok ->
        import Bitwise
        t = (b1 &&& 0b1110_0000) >>> 5
        l = (b1 &&& 0b0001_1000) >>> 3
        {:ok, t, l}

      error ->
        error
    end
  end

  def decode_ids_byte(_), do: {:error, :invalid_ids_byte}

  @doc """
  Returns human-readable error message for validation errors.

  ## Examples

      iex> IDSValidator.error_message({:error, :invalid_temporal_id})
      "Temporal ID must be 0-7"
      
      iex> IDSValidator.error_message({:error, :temporal_id_exceeds_capability})
      "Temporal ID exceeds stream capability (too many temporal layers)"
  """
  @spec error_message(validation_error()) :: String.t()
  def error_message({:error, :invalid_temporal_id}) do
    "Temporal ID must be 0-7"
  end

  def error_message({:error, :invalid_spatial_id}) do
    "Spatial ID must be 0-3"
  end

  def error_message({:error, :reserved_kid_bits_set}) do
    "Reserved KID bits (bits 0-2) in IDS byte must be 0"
  end

  def error_message({:error, :temporal_id_exceeds_capability}) do
    "Temporal ID exceeds stream capability (too many temporal layers)"
  end

  def error_message({:error, :spatial_id_exceeds_capability}) do
    "Spatial ID exceeds stream capability (too many spatial layers)"
  end

  def error_message({:error, :missing_ids}) do
    "IDS (temporal_id/spatial_id) required when M=1"
  end

  def error_message({:error, :invalid_ids_byte}) do
    "Invalid IDS byte format"
  end

  def error_message(_), do: "Unknown IDS validation error"

  # Private helpers

  defp validate_temporal_id(nil), do: {:error, :missing_ids}
  defp validate_temporal_id(t) when is_integer(t) and t >= 0 and t <= 7, do: :ok
  defp validate_temporal_id(_), do: {:error, :invalid_temporal_id}

  defp validate_spatial_id(nil), do: {:error, :missing_ids}
  defp validate_spatial_id(l) when is_integer(l) and l >= 0 and l <= 3, do: :ok
  defp validate_spatial_id(_), do: {:error, :invalid_spatial_id}

  defp validate_temporal_id_capability(nil, _ss), do: :ok

  defp validate_temporal_id_capability(temporal_id, %ScalabilityStructure{pictures: pictures}) do
    # Find maximum temporal_id in SS pictures
    max_temporal_id =
      pictures
      |> Enum.map(& &1.temporal_id)
      |> Enum.max(fn -> 0 end)

    if temporal_id <= max_temporal_id do
      :ok
    else
      {:error, :temporal_id_exceeds_capability}
    end
  end

  defp validate_spatial_id_capability(nil, _ss), do: :ok

  defp validate_spatial_id_capability(spatial_id, %ScalabilityStructure{n_s: n_s}) do
    # n_s is the number of spatial layers - 1 (so max spatial_id = n_s)
    if spatial_id <= n_s do
      :ok
    else
      {:error, :spatial_id_exceeds_capability}
    end
  end
end
