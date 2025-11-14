defmodule Membrane.RTP.AV1.ScalabilityStructure do
  @moduledoc """
  AV1 RTP Scalability Structure (SS) encoding and decoding per spec.

  The SS block describes the spatial and temporal layer structure of an AV1 stream.
  It is sent once at stream start or on keyframes when the Z bit is set in the payload descriptor.

  Structure:
  - Byte 0: N_S (3 bits) | Y (1 bit) | N_G (4 bits)
  - For each spatial layer (N_S+1 total):
    - Width (16 bits), Height (16 bits), Frame rate (if Y=0, 16 bits)
  - For each picture in dependency group (N_G total):
    - T (3 bits), U (2 bits), R (2 bits), reserved (1 bit)
    - For each spatial layer: P_DIFF (1 byte) indicating reference dependencies

  Maximum size: 255 bytes (practical limit for RTP payload descriptor)
  """

  import Bitwise

  @type spatial_layer :: %{
          width: non_neg_integer(),
          height: non_neg_integer(),
          frame_rate: non_neg_integer() | nil
        }

  @type picture_desc :: %{
          temporal_id: 0..7,
          spatial_id: 0..3,
          reference_count: 0..3,
          p_diffs: [non_neg_integer()]
        }

  @type t :: %__MODULE__{
          n_s: 0..7,
          y_flag: boolean(),
          n_g: 0..15,
          spatial_layers: [spatial_layer()],
          pictures: [picture_desc()]
        }

  defstruct n_s: 0,
            y_flag: false,
            n_g: 0,
            spatial_layers: [],
            pictures: []

  @max_ss_size 255

  @doc """
  Encodes a scalability structure into binary format.
  Returns {:ok, binary()} or {:error, reason}.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(%__MODULE__{} = ss) do
    with :ok <- validate_structure(ss),
         {:ok, header} <- encode_header(ss),
         {:ok, layers} <- encode_spatial_layers(ss),
         {:ok, pictures} <- encode_pictures(ss) do
      result = IO.iodata_to_binary([header, layers, pictures])

      if byte_size(result) > @max_ss_size do
        {:error, :ss_too_large}
      else
        {:ok, result}
      end
    end
  end

  @doc """
  Decodes a scalability structure from binary format.
  Returns {:ok, t(), rest} or {:error, reason}.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, atom()}
  def decode(binary) when byte_size(binary) > @max_ss_size do
    {:error, :ss_too_large}
  end

  def decode(<<b0, rest::binary>>) do
    n_s = (b0 &&& 0b1110_0000) >>> 5
    y = (b0 &&& 0b0001_0000) != 0
    n_g = b0 &&& 0b0000_1111

    with {:ok, layers, rest2} <- decode_spatial_layers(rest, n_s + 1, y, []),
         {:ok, pictures, rest3} <- decode_pictures(rest2, n_g, n_s, []) do
      ss = %__MODULE__{
        n_s: n_s,
        y_flag: y,
        n_g: n_g,
        spatial_layers: Enum.reverse(layers),
        pictures: Enum.reverse(pictures)
      }

      {:ok, ss, rest3}
    end
  end

  def decode(_), do: {:error, :invalid_ss_format}

  # Validation

  defp validate_structure(%__MODULE__{n_s: n_s, n_g: n_g, spatial_layers: layers, pictures: pics}) do
    cond do
      n_s > 7 ->
        {:error, :invalid_n_s}

      n_g > 15 ->
        {:error, :invalid_n_g}

      length(layers) != n_s + 1 ->
        {:error, :spatial_layer_count_mismatch}

      length(pics) != n_g ->
        {:error, :picture_count_mismatch}

      not Enum.all?(layers, &valid_spatial_layer?/1) ->
        {:error, :invalid_spatial_layer}

      not Enum.all?(pics, fn p -> valid_picture?(p, n_s) end) ->
        {:error, :invalid_picture_desc}

      true ->
        :ok
    end
  end

  defp valid_spatial_layer?(%{width: w, height: h})
       when w > 0 and h > 0 and w <= 65535 and h <= 65535,
       do: true

  defp valid_spatial_layer?(_), do: false

  defp valid_picture?(%{temporal_id: t, spatial_id: s, reference_count: r, p_diffs: diffs}, n_s)
       when t in 0..7 and s in 0..3 and r in 0..3 and is_list(diffs) do
    # p_diffs length should equal number of spatial layers
    length(diffs) == n_s + 1 and Enum.all?(diffs, &(&1 >= 0 and &1 <= 255))
  end

  defp valid_picture?(_, _), do: false

  # Encoding helpers

  defp encode_header(%__MODULE__{n_s: n_s, y_flag: y, n_g: n_g}) do
    y_bit = if y, do: 1, else: 0
    byte = n_s <<< 5 ||| y_bit <<< 4 ||| n_g
    {:ok, <<byte>>}
  end

  defp encode_spatial_layers(%__MODULE__{spatial_layers: layers, y_flag: y}) do
    encoded =
      Enum.map(layers, fn %{width: w, height: h} = layer ->
        frame_rate_bytes =
          if not y and Map.has_key?(layer, :frame_rate) and layer.frame_rate != nil do
            <<layer.frame_rate::16>>
          else
            <<>>
          end

        [<<w::16, h::16>>, frame_rate_bytes]
      end)

    {:ok, IO.iodata_to_binary(encoded)}
  end

  defp encode_pictures(%__MODULE__{pictures: pictures, n_s: n_s}) do
    encoded =
      Enum.map(pictures, fn %{temporal_id: t, spatial_id: s, reference_count: r, p_diffs: diffs} ->
        # T (3 bits) | U (spatial_id, 2 bits) | R (reference_count, 2 bits) | reserved (1 bit)
        byte0 = t <<< 5 ||| s <<< 3 ||| r <<< 1

        # P_DIFF values for each spatial layer
        p_diff_bytes =
          diffs
          |> Enum.take(n_s + 1)
          |> Enum.map(&<<&1::8>>)

        [<<byte0>>, p_diff_bytes]
      end)

    {:ok, IO.iodata_to_binary(encoded)}
  end

  # Decoding helpers

  defp decode_spatial_layers(rest, 0, _y, acc), do: {:ok, acc, rest}

  defp decode_spatial_layers(<<w::16, h::16, rest::binary>>, count, true = y, acc) do
    # Y=1 means no frame rate included
    layer = %{width: w, height: h, frame_rate: nil}
    decode_spatial_layers(rest, count - 1, y, [layer | acc])
  end

  defp decode_spatial_layers(<<w::16, h::16, fr::16, rest::binary>>, count, false = y, acc) do
    # Y=0 means frame rate is included
    layer = %{width: w, height: h, frame_rate: fr}
    decode_spatial_layers(rest, count - 1, y, [layer | acc])
  end

  defp decode_spatial_layers(_, _, _, _), do: {:error, :incomplete_spatial_layers}

  defp decode_pictures(rest, 0, _n_s, acc), do: {:ok, acc, rest}

  defp decode_pictures(<<byte0, rest::binary>>, count, n_s, acc) do
    t = (byte0 &&& 0b1110_0000) >>> 5
    s = (byte0 &&& 0b0001_1000) >>> 3
    r = (byte0 &&& 0b0000_0110) >>> 1

    # Read P_DIFF values for each spatial layer (n_s + 1 total)
    num_p_diffs = n_s + 1

    if byte_size(rest) < num_p_diffs do
      {:error, :incomplete_picture_desc}
    else
      <<p_diffs_bin::binary-size(num_p_diffs), rest2::binary>> = rest
      p_diffs = for <<pd::8 <- p_diffs_bin>>, do: pd

      picture = %{
        temporal_id: t,
        spatial_id: s,
        reference_count: r,
        p_diffs: p_diffs
      }

      decode_pictures(rest2, count - 1, n_s, [picture | acc])
    end
  end

  @doc """
  Creates a simple SS structure for a single spatial layer stream.
  """
  @spec simple(width :: pos_integer(), height :: pos_integer(), opts :: keyword()) :: t()
  def simple(width, height, opts \\ []) do
    frame_rate = Keyword.get(opts, :frame_rate, 30)
    temporal_layers = Keyword.get(opts, :temporal_layers, 1)

    # Single spatial layer
    spatial_layers = [%{width: width, height: height, frame_rate: frame_rate}]

    # Create picture descriptions for each temporal layer
    pictures =
      for t <- 0..(temporal_layers - 1) do
        %{
          temporal_id: t,
          spatial_id: 0,
          reference_count: if(t == 0, do: 0, else: 1),
          p_diffs: [if(t == 0, do: 0, else: 1)]
        }
      end

    %__MODULE__{
      n_s: 0,
      y_flag: false,
      n_g: length(pictures),
      spatial_layers: spatial_layers,
      pictures: pictures
    }
  end

  @doc """
  Creates an SS structure for SVC (Scalable Video Coding) with multiple spatial and temporal layers.
  """
  @spec svc(
          layers :: [{width :: pos_integer(), height :: pos_integer()}],
          temporal_layers :: pos_integer()
        ) :: t()
  def svc(spatial_resolutions, temporal_layers)
      when is_list(spatial_resolutions) and temporal_layers > 0 do
    n_s = length(spatial_resolutions) - 1

    spatial_layers =
      Enum.map(spatial_resolutions, fn {w, h} ->
        %{width: w, height: h, frame_rate: nil}
      end)

    # Create picture descriptions for all combinations of temporal and spatial layers
    pictures =
      for t <- 0..(temporal_layers - 1),
          s <- 0..n_s do
        %{
          temporal_id: t,
          spatial_id: s,
          reference_count: if(t == 0, do: 0, else: 1),
          # Simple dependency: reference previous frame in same spatial layer
          p_diffs: List.duplicate(if(t == 0, do: 0, else: 1), n_s + 1)
        }
      end

    %__MODULE__{
      n_s: n_s,
      y_flag: true,
      n_g: min(length(pictures), 15),
      spatial_layers: spatial_layers,
      pictures: Enum.take(pictures, 15)
    }
  end
end
