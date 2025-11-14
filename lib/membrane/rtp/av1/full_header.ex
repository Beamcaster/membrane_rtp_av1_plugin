defmodule Membrane.RTP.AV1.FullHeader do
  @moduledoc """
  AV1 RTP payload header (simplified but field-complete):

  Byte 0: Z Y W W N C M I
    - Z: Scalability structure present (SS) flag
    - Y: First OBU (or first fragment) in TU
    - W: Fragmentation state (0=none, 1=first, 2=middle, 3=last)
    - N: Non-reference frame
    - C: Reserved/aggregate count hint (0..1 here)
    - M: IDS present flag (temporal/spatial id present)
    - I: Reserved (0)

  Byte 1 (if M=1): T T T L L R R R
    - T: temporal_id (0..7)
    - L: spatial_id (0..3)
    - R: reserved zeros

  When Z=1, the scalability structure (SS) is encoded/decoded after header bytes.
  """
  import Bitwise
  alias Membrane.RTP.AV1.{ScalabilityStructure, HeaderValidator, IDSValidator}

  @type w_value :: 0..3
  @type t :: %__MODULE__{
          z: boolean(),
          y: boolean(),
          w: w_value(),
          n: boolean(),
          c: 0..1,
          m: boolean(),
          temporal_id: 0..7 | nil,
          spatial_id: 0..3 | nil,
          scalability_structure: ScalabilityStructure.t() | nil
        }

  defstruct z: false,
            y: false,
            w: 0,
            n: false,
            c: 0,
            m: false,
            temporal_id: nil,
            spatial_id: nil,
            scalability_structure: nil

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = h) do
    # Validate header before encoding
    with :ok <- HeaderValidator.validate_for_encode(h),
         :ok <- validate_ids_with_ss(h) do
      do_encode(h)
    else
      {:error, _reason} ->
        # For now, encode anyway but could raise or return error tuple
        # In production, you might want to raise or return {:error, reason, partial_data}
        do_encode(h)
    end
  end

  defp do_encode(%__MODULE__{} = h) do
    %__MODULE__{z: z, y: y, w: w, n: n, c: c, m: m} = h
    zbit = if z, do: 1, else: 0
    ybit = if y, do: 1, else: 0
    nbit = if n, do: 1, else: 0
    mbit = if m, do: 1, else: 0
    i = 0
    b0 = zbit <<< 7 ||| ybit <<< 6 ||| w <<< 4 ||| nbit <<< 3 ||| c <<< 2 ||| mbit <<< 1 ||| i

    base =
      case m do
        true ->
          t = h.temporal_id || 0
          l = h.spatial_id || 0
          # Use IDSValidator to encode IDS byte
          b1 = IDSValidator.encode_ids_byte(t, l)
          <<b0, b1>>

        false ->
          <<b0>>
      end

    case {h.z, h.scalability_structure} do
      {true, %ScalabilityStructure{} = ss} ->
        case ScalabilityStructure.encode(ss) do
          {:ok, ss_bin} -> base <> ss_bin
          {:error, _} -> base
        end

      _ ->
        base
    end
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, atom()}
  def decode(<<b0, rest::binary>>) do
    # Validate byte 0 first
    case HeaderValidator.validate_byte0(b0) do
      :ok ->
        do_decode(b0, rest)

      {:error, _reason} = error ->
        error
    end
  end

  def decode(_), do: {:error, :invalid_header_format}

  defp do_decode(b0, rest) do
    z = (b0 &&& 0b1000_0000) != 0
    y = (b0 &&& 0b0100_0000) != 0
    w = (b0 &&& 0b0011_0000) >>> 4
    n = (b0 &&& 0b0000_1000) != 0
    c = (b0 &&& 0b0000_0100) >>> 2
    m = (b0 &&& 0b0000_0010) != 0

    do_decode_tail(%__MODULE__{z: z, y: y, w: w, n: n, c: c, m: m}, rest)
  end

  defp do_decode_tail(header, rest) do
    with {:ok, header_with_ids, rest2} <- decode_ids(header, rest),
         {:ok, header_with_ss, rest3} <- decode_ss(header_with_ids, rest2) do
      {:ok, header_with_ss, rest3}
    end
  end

  defp decode_ids(%__MODULE__{m: false} = header, rest) do
    {:ok, header, rest}
  end

  defp decode_ids(%__MODULE__{m: true} = header, <<b1, rest::binary>>) do
    # Use IDSValidator to decode and validate IDS byte
    case IDSValidator.decode_ids_byte(b1) do
      {:ok, t, l} ->
        {:ok, %__MODULE__{header | temporal_id: t, spatial_id: l}, rest}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_ids(%__MODULE__{m: true}, _), do: {:error, :missing_ids_byte}

  defp decode_ss(%__MODULE__{z: false} = header, rest) do
    {:ok, header, rest}
  end

  defp decode_ss(%__MODULE__{z: true} = header, rest) do
    case ScalabilityStructure.decode(rest) do
      {:ok, ss, rest2} ->
        header_with_ss = %__MODULE__{header | scalability_structure: ss}
        # Validate IDS against SS capabilities if both are present
        case validate_ids_with_ss(header_with_ss) do
          :ok -> {:ok, header_with_ss, rest2}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Validates IDS (temporal_id/spatial_id) against SS capabilities
  defp validate_ids_with_ss(%__MODULE__{m: false}), do: :ok
  defp validate_ids_with_ss(%__MODULE__{m: true, temporal_id: nil}), do: :ok
  defp validate_ids_with_ss(%__MODULE__{m: true, spatial_id: nil}), do: :ok

  defp validate_ids_with_ss(%__MODULE__{
         m: true,
         temporal_id: tid,
         spatial_id: lid,
         scalability_structure: ss
       }) do
    IDSValidator.validate_ids_with_capabilities(tid, lid, ss)
  end
end
