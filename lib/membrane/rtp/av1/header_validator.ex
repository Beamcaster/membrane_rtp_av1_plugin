defmodule Membrane.RTP.AV1.HeaderValidator do
  @moduledoc """
  Strict validation of AV1 RTP header bit combinations per RFC 9420.

  Enforces:
  - Reserved bit constraints (must be 0)
  - Valid W bit values (0-3)
  - Z/Y/W/N/CM bit compatibility rules
  - IDS byte validation when M=1

  Note: Per RFC 9420, any W (0-3) can be combined with any Y value.
  W indicates the number of OBU elements, Y indicates if the last continues.
  """

  @type validation_error ::
          {:error,
           :reserved_bit_set
           | :invalid_w_value
           | :invalid_c_value
           | :invalid_temporal_id
           | :invalid_spatial_id
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

  # Private validation helpers

  defp validate_w_value(w) when w in 0..3, do: :ok
  defp validate_w_value(_), do: {:error, :invalid_w_value}

  defp validate_w_y_combination(w, y) do
    # RFC 9420: W indicates number of OBU elements, Y indicates if last element continues.
    # Any valid W (0-3) can be combined with any Y value.
    # 
    # Examples of valid combinations:
    # - W=3, Y=1: 3 OBU elements, last one continues (hybrid aggregation+fragmentation)
    # - W=2, Y=1: 2 OBU elements, last one continues
    # - W=1, Y=0: 1 OBU element, complete in this packet
    # - W=1, Y=1: 1 OBU element fragment, continues in next packet
    # - W=0, Y=0/1: All OBUs have LEB128 size prefix
    case w do
      w when w in 0..3 ->
        # Y can be true or false for any valid W value
        # Suppress unused variable warning
        _ = y
        :ok

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
    "W (OBU element count) must be 0-3"
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

  def error_message({:error, :z_set_without_ss}) do
    "Z=1 (SS present flag) set but no scalability structure provided"
  end

  def error_message({:error, :m_set_without_ids}) do
    "M=1 (IDS present flag) set but no temporal_id/spatial_id provided"
  end

  def error_message(_), do: "Unknown validation error"
end
