defmodule Membrane.RTP.AV1.HeaderValidator do
  @moduledoc """
  Strict validation of AV1 RTP header bit combinations per spec.

  Enforces:
  - Reserved bit constraints (must be 0)
  - Valid W bit state transitions and combinations
  - Z/Y/W/N/CM bit compatibility rules
  - IDS byte validation when M=1
  """

  @type validation_error ::
          {:error,
           :reserved_bit_set
           | :invalid_w_value
           | :invalid_w_y_combination
           | :invalid_c_value
           | :invalid_temporal_id
           | :invalid_spatial_id
           | :reserved_ids_bits_set
           | :z_set_without_ss
           | :m_set_without_ids}

  @doc """
  Validates a FullHeader structure before encoding.
  Returns :ok or {:error, reason}.
  """
  @spec validate_for_encode(map()) :: :ok | validation_error()
  def validate_for_encode(header) do
    with :ok <- validate_w_value(header.w),
         :ok <- validate_w_y_combination(header.w, header.y),
         :ok <- validate_c_value(header.c),
         :ok <- validate_z_ss_combination(header.z, header.scalability_structure),
         :ok <- validate_m_ids_combination(header.m, header.temporal_id, header.spatial_id) do
      :ok
    end
  end

  @doc """
  Validates the first byte of a decoded header.
  Checks reserved bits and bit combinations.
  """
  @spec validate_byte0(byte()) :: :ok | validation_error()
  def validate_byte0(b0) when is_integer(b0) and b0 >= 0 and b0 <= 255 do
    import Bitwise

    # Extract fields
    w = (b0 &&& 0b0011_0000) >>> 4
    y = (b0 &&& 0b0100_0000) != 0
    c = (b0 &&& 0b0000_0100) >>> 2
    i = b0 &&& 0b0000_0001

    # Check reserved I bit (must be 0)
    if i != 0 do
      {:error, :reserved_bit_set}
    else
      with :ok <- validate_w_value(w),
           :ok <- validate_w_y_combination(w, y),
           :ok <- validate_c_value(c) do
        :ok
      end
    end
  end

  @doc """
  Validates the IDS byte (byte 1 when M=1).
  Checks that reserved bits are 0 and fields are in valid ranges.
  """
  @spec validate_ids_byte(byte()) :: :ok | validation_error()
  def validate_ids_byte(b1) when is_integer(b1) and b1 >= 0 and b1 <= 255 do
    import Bitwise

    t = (b1 &&& 0b1110_0000) >>> 5
    l = (b1 &&& 0b0001_1000) >>> 3
    reserved = b1 &&& 0b0000_0111

    cond do
      reserved != 0 ->
        {:error, :reserved_ids_bits_set}

      t > 7 ->
        {:error, :invalid_temporal_id}

      l > 3 ->
        {:error, :invalid_spatial_id}

      true ->
        :ok
    end
  end

  # Private validation helpers

  defp validate_w_value(w) when w in 0..3, do: :ok
  defp validate_w_value(_), do: {:error, :invalid_w_value}

  defp validate_w_y_combination(w, y) do
    # Per spec: When W != 0 (fragmented), Y should indicate first fragment
    # W=1 (first fragment) should have Y=true
    # W=2 (middle fragment) should have Y=false
    # W=3 (last fragment) should have Y=false
    # W=0 (not fragmented) can have Y either true or false
    case {w, y} do
      {0, _} ->
        # Not fragmented, Y can be anything
        :ok

      {1, true} ->
        # First fragment with Y=true is correct
        :ok

      {1, false} ->
        # First fragment should have Y=true per spec
        {:error, :invalid_w_y_combination}

      {2, false} ->
        # Middle fragment with Y=false is correct
        :ok

      {2, true} ->
        # Middle fragment should not have Y=true
        {:error, :invalid_w_y_combination}

      {3, false} ->
        # Last fragment with Y=false is correct
        :ok

      {3, true} ->
        # Last fragment should not have Y=true
        {:error, :invalid_w_y_combination}

      _ ->
        {:error, :invalid_w_value}
    end
  end

  defp validate_c_value(c) when c in 0..1, do: :ok
  defp validate_c_value(_), do: {:error, :invalid_c_value}

  defp validate_z_ss_combination(false, _ss), do: :ok

  defp validate_z_ss_combination(true, nil) do
    # Z=1 but no SS provided
    {:error, :z_set_without_ss}
  end

  defp validate_z_ss_combination(true, %{__struct__: _}), do: :ok

  defp validate_m_ids_combination(false, nil, nil), do: :ok
  defp validate_m_ids_combination(false, _tid, _lid), do: :ok

  defp validate_m_ids_combination(true, nil, nil) do
    # M=1 but no IDS provided
    {:error, :m_set_without_ids}
  end

  defp validate_m_ids_combination(true, tid, lid) do
    with :ok <- validate_temporal_id(tid),
         :ok <- validate_spatial_id(lid) do
      :ok
    end
  end

  defp validate_temporal_id(nil), do: :ok
  defp validate_temporal_id(t) when is_integer(t) and t >= 0 and t <= 7, do: :ok
  defp validate_temporal_id(_), do: {:error, :invalid_temporal_id}

  defp validate_spatial_id(nil), do: :ok
  defp validate_spatial_id(l) when is_integer(l) and l >= 0 and l <= 3, do: :ok
  defp validate_spatial_id(_), do: {:error, :invalid_spatial_id}

  @doc """
  Returns a human-readable error message for a validation error.
  """
  @spec error_message(validation_error()) :: String.t()
  def error_message({:error, :reserved_bit_set}) do
    "Reserved bit I (bit 0) must be 0"
  end

  def error_message({:error, :invalid_w_value}) do
    "W (fragmentation state) must be 0-3"
  end

  def error_message({:error, :invalid_w_y_combination}) do
    "Invalid W/Y combination: W=1 (first fragment) must have Y=1, W=2/3 (middle/last) must have Y=0"
  end

  def error_message({:error, :invalid_c_value}) do
    "C (congestion management) must be 0 or 1"
  end

  def error_message({:error, :invalid_temporal_id}) do
    "Temporal ID must be 0-7"
  end

  def error_message({:error, :invalid_spatial_id}) do
    "Spatial ID must be 0-3"
  end

  def error_message({:error, :reserved_ids_bits_set}) do
    "Reserved bits in IDS byte (bits 0-2) must be 0"
  end

  def error_message({:error, :z_set_without_ss}) do
    "Z=1 (SS present flag) set but no scalability structure provided"
  end

  def error_message({:error, :m_set_without_ids}) do
    "M=1 (IDS present flag) set but no temporal_id/spatial_id provided"
  end

  def error_message(_), do: "Unknown validation error"
end
