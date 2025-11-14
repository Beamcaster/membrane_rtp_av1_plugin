defmodule Membrane.RTP.AV1.OBUHeader do
  @moduledoc """
  AV1 OBU (Open Bitstream Unit) header parsing per AV1 specification.

  OBU Header format (after LEB128 size):
  - Byte 0: F | obu_type (4 bits) | X | has_size | reserved (2 bits)
  - If X=1, Byte 1: temporal_id (3 bits) | spatial_id (2 bits) | reserved (3 bits)

  OBU Types:
  - 1: OBU_SEQUENCE_HEADER (non-discardable, critical)
  - 2: OBU_TEMPORAL_DELIMITER (non-discardable)
  - 3: OBU_FRAME_HEADER (non-discardable)
  - 4: OBU_TILE_GROUP (non-discardable for key frames)
  - 5: OBU_METADATA (discardable)
  - 6: OBU_FRAME (non-discardable, contains frame header + tiles)
  - 7: OBU_REDUNDANT_FRAME_HEADER (discardable)
  - 8: OBU_TILE_LIST (discardable, for scalability)
  - 15: OBU_PADDING (discardable)
  """

  import Bitwise

  @type obu_type ::
          :sequence_header
          | :temporal_delimiter
          | :frame_header
          | :tile_group
          | :metadata
          | :frame
          | :redundant_frame_header
          | :tile_list
          | :padding
          | :reserved

  @type t :: %__MODULE__{
          obu_forbidden_bit: 0..1,
          obu_type: obu_type(),
          obu_type_value: 0..15,
          obu_extension_flag: boolean(),
          obu_has_size_field: boolean(),
          temporal_id: 0..7 | nil,
          spatial_id: 0..3 | nil,
          discardable?: boolean()
        }

  defstruct obu_forbidden_bit: 0,
            obu_type: :reserved,
            obu_type_value: 0,
            obu_extension_flag: false,
            obu_has_size_field: false,
            temporal_id: nil,
            spatial_id: nil,
            discardable?: false

  # OBU type constants per AV1 spec
  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_frame_header 3
  @obu_tile_group 4
  @obu_metadata 5
  @obu_frame 6
  @obu_redundant_frame_header 7
  @obu_tile_list 8
  @obu_padding 15

  # Non-discardable OBU types (critical for decoding)
  @non_discardable_types [
    @obu_sequence_header,
    @obu_temporal_delimiter,
    @obu_frame_header,
    @obu_tile_group,
    @obu_frame
  ]

  @doc """
  Parses OBU header from binary (after LEB128 length has been read).

  Returns {:ok, obu_header, payload} or {:error, reason}.

  ## Examples

      # Parse OBU with type=6 (FRAME), extension flag=0
      iex> binary = <<0b0_0110_0_1_00, payload::binary>>
      iex> {:ok, header, ^payload} = OBUHeader.parse(binary)
      iex> header.obu_type
      :frame
      iex> header.obu_extension_flag
      false
      
      # Parse OBU with extension (temporal_id=3, spatial_id=1)
      iex> binary = <<0b0_0110_1_1_00, 0b011_01_000, payload::binary>>
      iex> {:ok, header, ^payload} = OBUHeader.parse(binary)
      iex> header.temporal_id
      3
      iex> header.spatial_id
      1
  """
  @spec parse(binary()) :: {:ok, t(), binary()} | {:error, atom()}
  def parse(<<b0, rest::binary>>) do
    # Parse byte 0: F | type (4 bits) | X | S | reserved (2 bits)
    forbidden_bit = (b0 &&& 0b1000_0000) >>> 7
    type_value = (b0 &&& 0b0111_1000) >>> 3
    extension_flag = (b0 &&& 0b0000_0100) != 0
    has_size_field = (b0 &&& 0b0000_0010) != 0

    # Validate forbidden bit
    if forbidden_bit != 0 do
      {:error, :obu_forbidden_bit_set}
    else
      obu_type = obu_type_from_value(type_value)
      discardable? = is_discardable?(type_value)

      # Parse extension header if present
      case parse_extension(rest, extension_flag) do
        {:ok, temporal_id, spatial_id, payload} ->
          header = %__MODULE__{
            obu_forbidden_bit: forbidden_bit,
            obu_type: obu_type,
            obu_type_value: type_value,
            obu_extension_flag: extension_flag,
            obu_has_size_field: has_size_field,
            temporal_id: temporal_id,
            spatial_id: spatial_id,
            discardable?: discardable?
          }

          {:ok, header, payload}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def parse(_), do: {:error, :invalid_obu_header}

  @doc """
  Parses multiple OBU headers from a list of OBU binaries.

  Each OBU binary should include its LEB128 length prefix.
  Returns list of parsed headers or {:error, reason} on first failure.

  ## Examples

      iex> obus = [obu1_with_leb, obu2_with_leb, obu3_with_leb]
      iex> {:ok, headers} = OBUHeader.parse_obus(obus)
      iex> length(headers)
      3
  """
  @spec parse_obus([binary()]) :: {:ok, [t()]} | {:error, atom()}
  def parse_obus(obu_list) when is_list(obu_list) do
    parse_obus_acc(obu_list, [])
  end

  defp parse_obus_acc([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_obus_acc([obu | rest], acc) do
    # Skip LEB128 length, then parse OBU header
    case skip_leb128(obu) do
      {:ok, payload} ->
        case parse(payload) do
          {:ok, header, _remaining} ->
            parse_obus_acc(rest, [header | acc])

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Determines the CM (Congestion Management) bit value for a set of OBUs.

  CM semantics:
  - CM=0: All OBUs in the packet are discardable
  - CM=1: OBUs have mixed discardability (at least one non-discardable)

  Returns 0 or 1.

  ## Examples

      # All discardable OBUs
      iex> headers = [%OBUHeader{obu_type: :metadata, discardable?: true},
      ...>            %OBUHeader{obu_type: :padding, discardable?: true}]
      iex> OBUHeader.determine_cm(headers)
      0
      
      # Mixed discardability
      iex> headers = [%OBUHeader{obu_type: :sequence_header, discardable?: false},
      ...>            %OBUHeader{obu_type: :frame, discardable?: false}]
      iex> OBUHeader.determine_cm(headers)
      1
  """
  @spec determine_cm([t()]) :: 0 | 1
  def determine_cm([]), do: 0

  def determine_cm(headers) when is_list(headers) do
    has_non_discardable? = Enum.any?(headers, fn h -> not h.discardable? end)

    if has_non_discardable? do
      1
    else
      0
    end
  end

  @doc """
  Determines CM bit for a list of OBU binaries (with LEB128 prefix).

  Parses OBU headers and returns CM value.
  Returns {:ok, 0 | 1} or {:error, reason}.

  ## Examples

      iex> obus = [frame_obu, metadata_obu]
      iex> {:ok, cm} = OBUHeader.determine_cm_from_obus(obus)
      iex> cm
      1
  """
  @spec determine_cm_from_obus([binary()]) :: {:ok, 0 | 1} | {:error, atom()}
  def determine_cm_from_obus(obu_list) when is_list(obu_list) do
    case parse_obus(obu_list) do
      {:ok, headers} ->
        {:ok, determine_cm(headers)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Checks if an OBU type is discardable.

  Non-discardable types: SEQUENCE_HEADER, TEMPORAL_DELIMITER, FRAME_HEADER, TILE_GROUP, FRAME
  Discardable types: METADATA, REDUNDANT_FRAME_HEADER, TILE_LIST, PADDING

  ## Examples

      iex> OBUHeader.discardable?(:frame)
      false
      
      iex> OBUHeader.discardable?(:metadata)
      true
      
      iex> OBUHeader.discardable?(:sequence_header)
      false
  """
  @spec discardable?(obu_type()) :: boolean()
  def discardable?(:sequence_header), do: false
  def discardable?(:temporal_delimiter), do: false
  def discardable?(:frame_header), do: false
  def discardable?(:tile_group), do: false
  def discardable?(:frame), do: false
  def discardable?(:metadata), do: true
  def discardable?(:redundant_frame_header), do: true
  def discardable?(:tile_list), do: true
  def discardable?(:padding), do: true
  def discardable?(:reserved), do: true

  @doc """
  Returns human-readable name for OBU type.

  ## Examples

      iex> OBUHeader.obu_type_name(:frame)
      "OBU_FRAME"
      
      iex> OBUHeader.obu_type_name(:sequence_header)
      "OBU_SEQUENCE_HEADER"
  """
  @spec obu_type_name(obu_type()) :: String.t()
  def obu_type_name(:sequence_header), do: "OBU_SEQUENCE_HEADER"
  def obu_type_name(:temporal_delimiter), do: "OBU_TEMPORAL_DELIMITER"
  def obu_type_name(:frame_header), do: "OBU_FRAME_HEADER"
  def obu_type_name(:tile_group), do: "OBU_TILE_GROUP"
  def obu_type_name(:metadata), do: "OBU_METADATA"
  def obu_type_name(:frame), do: "OBU_FRAME"
  def obu_type_name(:redundant_frame_header), do: "OBU_REDUNDANT_FRAME_HEADER"
  def obu_type_name(:tile_list), do: "OBU_TILE_LIST"
  def obu_type_name(:padding), do: "OBU_PADDING"
  def obu_type_name(:reserved), do: "OBU_RESERVED"

  # Private helpers

  defp obu_type_from_value(@obu_sequence_header), do: :sequence_header
  defp obu_type_from_value(@obu_temporal_delimiter), do: :temporal_delimiter
  defp obu_type_from_value(@obu_frame_header), do: :frame_header
  defp obu_type_from_value(@obu_tile_group), do: :tile_group
  defp obu_type_from_value(@obu_metadata), do: :metadata
  defp obu_type_from_value(@obu_frame), do: :frame
  defp obu_type_from_value(@obu_redundant_frame_header), do: :redundant_frame_header
  defp obu_type_from_value(@obu_tile_list), do: :tile_list
  defp obu_type_from_value(@obu_padding), do: :padding
  defp obu_type_from_value(_), do: :reserved

  defp is_discardable?(type_value) do
    type_value not in @non_discardable_types
  end

  defp parse_extension(rest, false) do
    # No extension header
    {:ok, nil, nil, rest}
  end

  defp parse_extension(<<b1, rest::binary>>, true) do
    # Extension header: temporal_id (3 bits) | spatial_id (2 bits) | reserved (3 bits)
    temporal_id = (b1 &&& 0b1110_0000) >>> 5
    spatial_id = (b1 &&& 0b0001_1000) >>> 3
    reserved = b1 &&& 0b0000_0111

    if reserved != 0 do
      {:error, :obu_extension_reserved_bits_set}
    else
      {:ok, temporal_id, spatial_id, rest}
    end
  end

  defp parse_extension(_, true) do
    {:error, :missing_obu_extension_byte}
  end

  defp skip_leb128(<<byte, rest::binary>>) do
    if (byte &&& 0x80) == 0 do
      # Single-byte LEB128
      {:ok, rest}
    else
      # Multi-byte LEB128, skip remaining bytes
      skip_leb128_continuation(rest)
    end
  end

  defp skip_leb128(_), do: {:error, :invalid_leb128}

  defp skip_leb128_continuation(<<byte, rest::binary>>) do
    if (byte &&& 0x80) == 0 do
      {:ok, rest}
    else
      skip_leb128_continuation(rest)
    end
  end

  defp skip_leb128_continuation(_), do: {:error, :invalid_leb128}
end
