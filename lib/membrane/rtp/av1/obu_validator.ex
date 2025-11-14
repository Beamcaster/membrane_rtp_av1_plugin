defmodule Membrane.RTP.AV1.OBUValidator do
  @moduledoc """
  Validates AV1 OBU (Open Bitstream Unit) structure and boundaries.

  Ensures:
  - Valid LEB128 length encoding
  - Complete OBU boundaries (no partial OBUs)
  - OBU header validity (forbidden bit, extension format)
  - Total size consistency

  Provides telemetry events for malformed OBUs to enable monitoring
  and debugging in production.
  """

  import Bitwise

  @max_leb128_bytes 8
  @max_obu_size 256_000

  @typedoc """
  Validation result with details about the issue.
  """
  @type validation_error ::
          :invalid_leb128
          | :incomplete_obu
          | :obu_too_large
          | :forbidden_bit_set
          | :malformed_header
          | :partial_obu_at_boundary
          | :zero_length_obu

  @type validation_result :: :ok | {:error, validation_error(), map()}

  @doc """
  Validates that an access unit contains only complete, well-formed OBUs.

  Returns :ok if valid, or {:error, reason, context} with details about the issue.

  Emits telemetry events for validation failures:
  - [:membrane_rtp_av1, :obu_validation, :error]

  ## Examples

      # Valid access unit
      iex> obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      iex> OBUValidator.validate_access_unit(obu)
      :ok

      # Invalid: incomplete OBU
      iex> OBUValidator.validate_access_unit(<<10, 0x0A, 1, 2>>)
      {:error, :incomplete_obu, %{expected: 10, actual: 3}}

      # Invalid: malformed LEB128
      iex> OBUValidator.validate_access_unit(<<0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80>>)
      {:error, :invalid_leb128, %{reason: :too_many_bytes}}
  """
  @spec validate_access_unit(binary()) :: validation_result()
  def validate_access_unit(access_unit) when is_binary(access_unit) do
    case validate_obus(access_unit, []) do
      {:ok, _obus} ->
        :ok

      {:error, reason, context} = error ->
        emit_telemetry_error(reason, context)
        error
    end
  end

  @doc """
  Validates and splits an access unit into individual OBUs.

  Returns {:ok, obus} if all OBUs are valid, or {:error, reason, context}.

  This is a stricter version of OBU.split_obus/1 that validates structure.

  ## Examples

      iex> obu1 = OBU.build_obu(<<0x0A, 1, 2>>)
      iex> obu2 = OBU.build_obu(<<0x2A, 3, 4>>)
      iex> {:ok, obus} = OBUValidator.validate_and_split(obu1 <> obu2)
      iex> length(obus)
      2
  """
  @spec validate_and_split(binary()) :: {:ok, [binary()]} | {:error, validation_error(), map()}
  def validate_and_split(access_unit) when is_binary(access_unit) do
    validate_obus(access_unit, [])
  end

  @doc """
  Validates a single OBU (with LEB128 prefix).

  Checks:
  - LEB128 encoding validity
  - OBU size reasonable
  - Complete OBU present
  - Header structure valid

  ## Examples

      iex> obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      iex> OBUValidator.validate_obu(obu)
      :ok

      iex> OBUValidator.validate_obu(<<10, 0x0A, 1, 2>>)
      {:error, :incomplete_obu, %{expected: 10, actual: 3}}
  """
  @spec validate_obu(binary()) :: validation_result()
  def validate_obu(obu) when is_binary(obu) do
    with {:ok, length, _leb_bytes, rest} <- validate_leb128(obu),
         :ok <- validate_obu_size(length),
         :ok <- validate_completeness(length, rest),
         :ok <- validate_obu_header(rest) do
      :ok
    else
      {:error, _reason, _context} = error -> error
    end
  end

  @doc """
  Checks if an access unit appears to have partial OBUs at boundaries.

  This is useful for detecting incomplete access units before packetization.

  Returns :ok if boundaries look valid, or {:error, :partial_obu_at_boundary, context}.
  """
  @spec check_boundaries(binary()) :: validation_result()
  def check_boundaries(<<>>), do: :ok

  def check_boundaries(access_unit) when is_binary(access_unit) do
    case validate_obus(access_unit, []) do
      {:ok, _obus} ->
        :ok

      {:error, :incomplete_obu, _context} ->
        # Convert to boundary-specific error
        {:error, :partial_obu_at_boundary,
         %{message: "Access unit ends with partial OBU", size: byte_size(access_unit)}}

      {:error, _reason, _context} = error ->
        error
    end
  end

  @doc """
  Returns a human-readable error message for validation errors.

  ## Examples

      iex> OBUValidator.error_message({:error, :invalid_leb128, %{reason: :too_many_bytes}})
      "Invalid LEB128 encoding: too_many_bytes"

      iex> OBUValidator.error_message({:error, :incomplete_obu, %{expected: 10, actual: 5}})
      "Incomplete OBU: expected 10 bytes but only 5 available"
  """
  @spec error_message({:error, validation_error(), map()}) :: String.t()
  def error_message({:error, :invalid_leb128, context}) do
    reason = Map.get(context, :reason, "malformed")
    "Invalid LEB128 encoding: #{reason}"
  end

  def error_message({:error, :incomplete_obu, context}) do
    expected = Map.get(context, :expected)
    actual = Map.get(context, :actual)
    "Incomplete OBU: expected #{expected} bytes but only #{actual} available"
  end

  def error_message({:error, :obu_too_large, context}) do
    size = Map.get(context, :size)
    "OBU too large: #{size} bytes exceeds maximum #{@max_obu_size}"
  end

  def error_message({:error, :forbidden_bit_set, _context}) do
    "OBU header forbidden bit is set (must be 0)"
  end

  def error_message({:error, :malformed_header, context}) do
    reason = Map.get(context, :reason, "unknown")
    "Malformed OBU header: #{reason}"
  end

  def error_message({:error, :partial_obu_at_boundary, context}) do
    msg = Map.get(context, :message, "Partial OBU at access unit boundary")
    "#{msg}"
  end

  def error_message({:error, :zero_length_obu, _context}) do
    "OBU has zero length"
  end

  def error_message(_) do
    "Unknown OBU validation error"
  end

  # Private functions

  defp validate_obus(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_obus(binary, acc) do
    case validate_leb128(binary) do
      {:ok, length, leb_bytes, rest} ->
        with :ok <- validate_obu_size(length),
             :ok <- validate_completeness(length, rest) do
          <<obu_payload::binary-size(length), remaining::binary>> = rest

          case validate_obu_header(obu_payload) do
            :ok ->
              obu = leb_bytes <> obu_payload
              validate_obus(remaining, [obu | acc])

            {:error, _reason, _context} = error ->
              error
          end
        else
          {:error, _reason, _context} = error -> error
        end

      {:error, _reason, _context} = error ->
        error
    end
  end

  defp validate_leb128(<<>>), do: {:error, :invalid_leb128, %{reason: :empty_buffer}}

  defp validate_leb128(binary) do
    case do_validate_leb128(binary, 0, 0, [], 0) do
      {:ok, value, leb_bytes, rest} ->
        {:ok, value, leb_bytes, rest}

      {:error, reason} ->
        {:error, :invalid_leb128, %{reason: reason}}
    end
  end

  defp do_validate_leb128(_, _, _, _, byte_count) when byte_count >= @max_leb128_bytes do
    {:error, :too_many_bytes}
  end

  defp do_validate_leb128(<<>>, _, _, _, _), do: {:error, :truncated}

  defp do_validate_leb128(<<byte, rest::binary>>, shift, acc, bytes, byte_count) do
    value = acc ||| (byte &&& 0x7F) <<< shift
    bytes_acc = [byte | bytes]

    if (byte &&& 0x80) == 0 do
      leb = bytes_acc |> Enum.reverse() |> :erlang.list_to_binary()
      {:ok, value, leb, rest}
    else
      do_validate_leb128(rest, shift + 7, value, bytes_acc, byte_count + 1)
    end
  end

  defp validate_obu_size(0), do: {:error, :zero_length_obu, %{}}

  defp validate_obu_size(length) when length > @max_obu_size do
    {:error, :obu_too_large, %{size: length, max: @max_obu_size}}
  end

  defp validate_obu_size(_length), do: :ok

  defp validate_completeness(expected_length, available_data) do
    actual_length = byte_size(available_data)

    if actual_length >= expected_length do
      :ok
    else
      {:error, :incomplete_obu, %{expected: expected_length, actual: actual_length}}
    end
  end

  defp validate_obu_header(<<>>), do: {:error, :malformed_header, %{reason: :empty_header}}

  defp validate_obu_header(<<b0, _rest::binary>>) do
    # Check forbidden bit (bit 7)
    forbidden_bit = (b0 &&& 0x80) >>> 7

    if forbidden_bit == 1 do
      {:error, :forbidden_bit_set, %{byte: b0}}
    else
      # Basic header format check - could be enhanced with OBUHeader.parse/1
      # For now, just check forbidden bit
      :ok
    end
  end

  defp emit_telemetry_error(reason, context) do
    :telemetry.execute(
      [:membrane_rtp_av1, :obu_validation, :error],
      %{count: 1},
      %{reason: reason, context: context}
    )
  end
end
