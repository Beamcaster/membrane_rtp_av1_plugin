defmodule Membrane.RTP.AV1.FrameHeader do
  @moduledoc """
  Minimal AV1 frame header parser for RTP signaling.

  Extracts only fields needed for RTP packetization:
  - Frame type (KEY_FRAME, INTER_FRAME, etc.)
  - show_frame flag
  - show_existing_frame flag
  - error_resilient_mode flag

  This is NOT a complete frame header parser. Full parsing requires
  sequence header context and is unnecessary for RTP packetization.

  ## AV1 Specification Reference

  Section 5.9: frame_header_obu() and uncompressed_header()

  Frame types:
  - KEY_FRAME (0): Intra-coded frame, can be used as random access point
  - INTER_FRAME (1): References other frames using motion compensation
  - INTRA_ONLY_FRAME (2): Intra-coded but not a key frame
  - SWITCH_FRAME (3): Clean random access point for layer switching

  ## Usage

      # Parse from OBU_FRAME or OBU_FRAME_HEADER payload
      # show_existing_frame=0, frame_type=KEY_FRAME
      iex> payload = <<0::1, 0::2, 0::5>>
      iex> {:ok, header} = FrameHeader.parse_minimal(payload)
      iex> header.frame_type
      :key_frame
      iex> FrameHeader.starts_temporal_unit?(header)
      true

      # KEY_FRAME with show_frame=1 starts new temporal unit
      iex> header = %FrameHeader{frame_type: :key_frame, show_frame: true}
      iex> FrameHeader.starts_temporal_unit?(header)
      true

      # INTER_FRAME does not start temporal unit
      iex> header = %FrameHeader{frame_type: :inter_frame, show_frame: true}
      iex> FrameHeader.starts_temporal_unit?(header)
      false
  """

  @type frame_type :: :key_frame | :inter_frame | :intra_only_frame | :switch_frame

  @type t :: %__MODULE__{
          frame_type: frame_type(),
          show_frame: boolean(),
          show_existing_frame: boolean(),
          error_resilient_mode: boolean()
        }

  defstruct frame_type: :inter_frame,
            show_frame: true,
            show_existing_frame: false,
            error_resilient_mode: false

  @frame_type_key 0
  @frame_type_inter 1
  @frame_type_intra_only 2
  @frame_type_switch 3

  @doc """
  Parse minimal frame header information from OBU payload.

  This parser extracts only the fields needed for RTP signaling:
  - show_existing_frame (1 bit)
  - frame_type (2 bits, if show_existing_frame=0)
  - show_frame (1 bit)
  - error_resilient_mode (1 bit)

  Full frame header parsing requires sequence header context and is
  beyond the scope of RTP packetization.

  ## Examples

      # KEY_FRAME (show_existing_frame=0, frame_type=0)
      iex> FrameHeader.parse_minimal(<<0::1, 0::2, 0::5>>)
      {:ok, %FrameHeader{
        frame_type: :key_frame,
        show_frame: true,
        show_existing_frame: false,
        error_resilient_mode: true
      }}

      # INTER_FRAME (show_existing_frame=0, frame_type=1)
      iex> FrameHeader.parse_minimal(<<0::1, 1::2, 1::1, 0::1, 0::3>>)
      {:ok, %FrameHeader{
        frame_type: :inter_frame,
        show_frame: true,
        show_existing_frame: false,
        error_resilient_mode: false
      }}

      # show_existing_frame=1 (displays previously decoded frame)
      iex> FrameHeader.parse_minimal(<<1::1, 0::3, 0::4>>)
      {:ok, %FrameHeader{
        frame_type: :inter_frame,
        show_existing_frame: true,
        show_frame: true,
        error_resilient_mode: false
      }}
  """
  @spec parse_minimal(binary()) :: {:ok, t()} | {:error, atom()}
  def parse_minimal(data) when is_binary(data) and byte_size(data) > 0 do
    case parse_bitstream(data) do
      {:ok, header} -> {:ok, header}
      {:error, _reason} = error -> error
    end
  end

  def parse_minimal(_), do: {:error, :invalid_bitstream}

  @doc """
  Determine if this frame starts a new temporal unit.

  Per AV1 spec section 7.5, a temporal unit starts with:
  - KEY_FRAME (always shown, intra-coded)
  - INTRA_ONLY_FRAME with show_frame=1
  - SWITCH_FRAME (always shown, clean random access)

  INTER_FRAME never starts a new temporal unit.

  ## Examples

      iex> FrameHeader.starts_temporal_unit?(%FrameHeader{frame_type: :key_frame})
      true

      iex> FrameHeader.starts_temporal_unit?(%FrameHeader{frame_type: :switch_frame})
      true

      iex> FrameHeader.starts_temporal_unit?(%FrameHeader{
      ...>   frame_type: :intra_only_frame,
      ...>   show_frame: true
      ...> })
      true

      iex> FrameHeader.starts_temporal_unit?(%FrameHeader{
      ...>   frame_type: :intra_only_frame,
      ...>   show_frame: false
      ...> })
      false

      iex> FrameHeader.starts_temporal_unit?(%FrameHeader{frame_type: :inter_frame})
      false
  """
  @spec starts_temporal_unit?(t()) :: boolean()
  def starts_temporal_unit?(%__MODULE__{frame_type: :key_frame}), do: true
  def starts_temporal_unit?(%__MODULE__{frame_type: :switch_frame}), do: true

  def starts_temporal_unit?(%__MODULE__{frame_type: :intra_only_frame, show_frame: true}),
    do: true

  def starts_temporal_unit?(_), do: false

  @doc """
  Determine if this frame is displayable (contributes to output).

  Frames with show_frame=1 or show_existing_frame=1 are displayable.

  ## Examples

      iex> FrameHeader.displayable?(%FrameHeader{show_frame: true})
      true

      iex> FrameHeader.displayable?(%FrameHeader{show_existing_frame: true})
      true

      iex> FrameHeader.displayable?(%FrameHeader{show_frame: false, show_existing_frame: false})
      false
  """
  @spec displayable?(t()) :: boolean()
  def displayable?(%__MODULE__{show_frame: true}), do: true
  def displayable?(%__MODULE__{show_existing_frame: true}), do: true
  def displayable?(_), do: false

  @doc """
  Get human-readable name for frame type.

  ## Examples

      iex> FrameHeader.frame_type_name(:key_frame)
      "KEY_FRAME"

      iex> FrameHeader.frame_type_name(:inter_frame)
      "INTER_FRAME"

      iex> FrameHeader.frame_type_name(:intra_only_frame)
      "INTRA_ONLY_FRAME"

      iex> FrameHeader.frame_type_name(:switch_frame)
      "SWITCH_FRAME"
  """
  @spec frame_type_name(frame_type()) :: String.t()
  def frame_type_name(:key_frame), do: "KEY_FRAME"
  def frame_type_name(:inter_frame), do: "INTER_FRAME"
  def frame_type_name(:intra_only_frame), do: "INTRA_ONLY_FRAME"
  def frame_type_name(:switch_frame), do: "SWITCH_FRAME"

  # Private functions

  defp parse_bitstream(<<data::bitstring>>) do
    with {:ok, show_existing, rest} <- parse_show_existing_frame(data),
         {:ok, frame_type, rest} <- parse_frame_type(show_existing, rest),
         {:ok, show_frame, rest} <- parse_show_frame(frame_type, show_existing, rest),
         {:ok, error_resilient, _rest} <- parse_error_resilient(frame_type, rest) do
      header = %__MODULE__{
        show_existing_frame: show_existing,
        frame_type: frame_type,
        show_frame: show_frame,
        error_resilient_mode: error_resilient
      }

      {:ok, header}
    else
      {:error, _reason} = error -> error
    end
  end

  defp parse_bitstream(_), do: {:error, :invalid_bitstream}

  defp parse_show_existing_frame(<<flag::1, rest::bitstring>>) do
    {:ok, flag == 1, rest}
  end

  defp parse_show_existing_frame(_), do: {:error, :truncated_show_existing_frame}

  defp parse_frame_type(true, rest) do
    # show_existing_frame=1: treated as INTER_FRAME for RTP purposes
    {:ok, :inter_frame, rest}
  end

  defp parse_frame_type(false, <<type::2, rest::bitstring>>) do
    frame_type =
      case type do
        @frame_type_key -> :key_frame
        @frame_type_inter -> :inter_frame
        @frame_type_intra_only -> :intra_only_frame
        @frame_type_switch -> :switch_frame
      end

    {:ok, frame_type, rest}
  end

  defp parse_frame_type(_, _), do: {:error, :truncated_frame_type}

  defp parse_show_frame(:key_frame, _show_existing, rest) do
    # KEY_FRAME always has show_frame=1
    {:ok, true, rest}
  end

  defp parse_show_frame(:switch_frame, _show_existing, rest) do
    # SWITCH_FRAME always has show_frame=1
    {:ok, true, rest}
  end

  defp parse_show_frame(_frame_type, true, rest) do
    # show_existing_frame=1 implies show_frame=1
    {:ok, true, rest}
  end

  defp parse_show_frame(_frame_type, false, <<flag::1, rest::bitstring>>) do
    {:ok, flag == 1, rest}
  end

  defp parse_show_frame(_, _, _), do: {:error, :truncated_show_frame}

  defp parse_error_resilient(:key_frame, rest) do
    # KEY_FRAME always has error_resilient_mode=1
    {:ok, true, rest}
  end

  defp parse_error_resilient(:switch_frame, rest) do
    # SWITCH_FRAME always has error_resilient_mode=1
    {:ok, true, rest}
  end

  defp parse_error_resilient(:intra_only_frame, <<flag::1, rest::bitstring>>) do
    {:ok, flag == 1, rest}
  end

  defp parse_error_resilient(:inter_frame, <<flag::1, rest::bitstring>>) do
    {:ok, flag == 1, rest}
  end

  defp parse_error_resilient(_, _), do: {:error, :truncated_error_resilient}
end
