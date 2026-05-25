defmodule Membrane.RTP.AV1.Test.AV1Generators do
  @moduledoc """
  Shared StreamData generators and plain helpers for property-based tests.

  Generators model the on-wire structures defined by RFC 9628 (RTP Payload
  Format for AV1) and the AV1 bitstream specification (OBU low-overhead format,
  LEB128). Plain helpers reconstruct OBUs from depayloader output so properties
  can compare against the generated input.
  """

  use ExUnitProperties

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.RTP.AV1.Depayloader.State
  alias Membrane.RTP.AV1.LEB128
  alias Membrane.RTP.AV1.ScalabilityStructure

  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_frame_header 3
  @obu_tile_group 4
  @obu_metadata 5
  @obu_frame 6
  @obu_tile_list 8
  @obu_padding 15

  @semantic_keys [:type, :has_extension, :temporal_id, :spatial_id, :payload]

  # ===========================================================================
  # LEB128
  # ===========================================================================

  @doc "Unsigned integers within the AV1 `leb128()` valid range (fits 32 bits)."
  def leb128_value do
    StreamData.frequency([
      {3, StreamData.integer(0..0xFFFFFFFF)},
      {1,
       StreamData.member_of([
         0,
         1,
         127,
         128,
         16_383,
         16_384,
         2_097_151,
         2_097_152,
         268_435_455,
         0xFFFFFFFF
       ])}
    ])
  end

  @doc """
  Integers needing more than 56 bits, whose LEB128 encoding therefore exceeds
  the AV1 `leb128()` 8-byte limit.
  """
  def leb128_oversize_value do
    StreamData.integer((1 <<< 57)..(1 <<< 80))
  end

  @doc """
  A binary that is a strict prefix of a multi-byte LEB128 encoding, consisting
  only of continuation bytes (high bit set). Decoding it must fail.
  """
  def truncated_leb128 do
    gen all(bytes <- StreamData.list_of(StreamData.integer(0..127), min_length: 1, max_length: 7)) do
      bytes
      |> Enum.map(&(&1 ||| 0x80))
      |> :erlang.list_to_binary()
    end
  end

  # ===========================================================================
  # OBUs (AV1 bitstream spec section 5.3)
  # ===========================================================================

  @doc "Any recognised OBU type."
  def obu_type do
    StreamData.member_of([
      @obu_sequence_header,
      @obu_temporal_delimiter,
      @obu_frame_header,
      @obu_tile_group,
      @obu_metadata,
      @obu_frame,
      @obu_tile_list,
      @obu_padding
    ])
  end

  @doc """
  An arbitrary OBU.

  Produces a map with the structured fields plus `:bytes`, the on-wire encoding
  `header (+ extension) (+ leb128 size) (+ payload)`.
  """
  def obu do
    gen all(
          type <- obu_type(),
          has_extension <- StreamData.boolean(),
          has_size <- StreamData.boolean(),
          ext <- StreamData.integer(0..255),
          payload <- StreamData.binary(max_length: 40)
        ) do
      build_obu(type, has_extension, has_size, ext, payload)
    end
  end

  @doc "An OBU of a fixed type with a non-empty payload (so it is always fragmentable)."
  def obu_of_type(type) do
    gen all(
          has_extension <- StreamData.boolean(),
          has_size <- StreamData.boolean(),
          ext <- StreamData.integer(0..255),
          payload <- StreamData.binary(min_length: 1, max_length: 40)
        ) do
      build_obu(type, has_extension, has_size, ext, payload)
    end
  end

  @doc """
  A one-byte OBU whose header claims an extension that is not actually present.

  Exercises the `parse_obu_header/1` truncated-extension fallback.
  """
  def obu_header_only_with_extension do
    gen all(
          type <- StreamData.integer(0..15),
          has_size <- StreamData.integer(0..1)
        ) do
      <<0::1, type::4, 1::1, has_size::1, 0::1>>
    end
  end

  @doc "OBU elements that together form one coded frame's data."
  def frame_obus do
    StreamData.one_of([
      StreamData.map(obu_of_type(@obu_frame), &[&1]),
      StreamData.fixed_list([
        obu_of_type(@obu_frame_header),
        obu_of_type(@obu_tile_group)
      ])
    ])
  end

  @doc """
  A temporal unit that starts a coded video sequence: a sequence header OBU
  followed by frame data, optionally preceded by a metadata OBU.
  """
  def keyframe_temporal_unit do
    gen all(
          seq_header <- obu_of_type(@obu_sequence_header),
          metadata <- StreamData.list_of(obu_of_type(@obu_metadata), max_length: 1),
          frame <- frame_obus()
        ) do
      [seq_header] ++ metadata ++ frame
    end
  end

  @doc "A temporal unit with frame data but no sequence header."
  def inter_temporal_unit do
    gen all(
          metadata <- StreamData.list_of(obu_of_type(@obu_metadata), max_length: 1),
          frame <- frame_obus()
        ) do
      metadata ++ frame
    end
  end

  # ===========================================================================
  # RTP packetization (RFC 9628 sections 4.2, 4.3, 4.3.2, 4.4)
  # ===========================================================================

  @doc """
  Packetizes a temporal unit into a list of `{rtp_payload, marker}` tuples.

  `w` selects the OBU-element framing: `0` uses LEB128 length prefixes for every
  element in a single packet; `1..3` chunks the OBUs into packets of that many
  elements. The `n` bit is set on the first packet only; the marker on the last.
  """
  def packetize(obu_list, w, n) do
    obu_list
    |> Enum.map(& &1.bytes)
    |> packetize_bytes(w, n)
  end

  defp packetize_bytes(obu_binaries, 0, n) do
    body =
      for obu <- obu_binaries, into: <<>> do
        LEB128.encode(byte_size(obu)) <> obu
      end

    [{<<0::1, 0::1, 0::2, n::1, 0::3>> <> body, true}]
  end

  defp packetize_bytes(obu_binaries, w, n) when w in 1..3 do
    chunks = Enum.chunk_every(obu_binaries, w)
    last_index = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      element_count = length(chunk)
      n_bit = if index == 0, do: n, else: 0
      {complete, [last]} = Enum.split(chunk, element_count - 1)

      prefixed =
        for obu <- complete, into: <<>> do
          LEB128.encode(byte_size(obu)) <> obu
        end

      body = prefixed <> last
      header = <<0::1, 0::1, element_count::2, n_bit::1, 0::3>>
      {header <> body, index == last_index}
    end)
  end

  @doc """
  Packetizes a temporal unit as one OBU per packet (W=1), fragmenting the OBU at
  `frag_index` across `pieces` packets using the Z/Y bits (RFC 9628 section 4.3.2).
  """
  def packetize_fragmented(obu_list, frag_index, pieces, n) do
    binaries = Enum.map(obu_list, & &1.bytes)
    last_obu_index = length(binaries) - 1
    frag_index = rem(frag_index, length(binaries))

    binaries
    |> Enum.with_index()
    |> Enum.flat_map(fn {obu, index} ->
      n_bit = if index == 0, do: n, else: 0
      last_obu? = index == last_obu_index

      if index == frag_index do
        actual_pieces = min(pieces, byte_size(obu)) |> max(1)

        obu
        |> split_into(actual_pieces)
        |> fragment_packets(n_bit, last_obu?)
      else
        [{<<0::1, 0::1, 1::2, n_bit::1, 0::3>> <> obu, last_obu?}]
      end
    end)
  end

  defp fragment_packets([single], n, last_obu?) do
    [{<<0::1, 0::1, 1::2, n::1, 0::3>> <> single, last_obu?}]
  end

  defp fragment_packets(pieces, n, last_obu?) do
    count = length(pieces)

    pieces
    |> Enum.with_index()
    |> Enum.map(fn {piece, index} ->
      {z, y} =
        cond do
          index == 0 -> {0, 1}
          index == count - 1 -> {1, 0}
          true -> {1, 1}
        end

      n_bit = if index == 0, do: n, else: 0
      marker = last_obu? and index == count - 1
      {<<z::1, y::1, 1::2, n_bit::1, 0::3>> <> piece, marker}
    end)
  end

  @doc "Converts `{payload, marker}` tuples into RTP `Membrane.Buffer` structs."
  def to_buffers(packets, timestamp, pts \\ nil) do
    Enum.map(packets, fn {payload, marker} ->
      %Buffer{
        payload: payload,
        pts: pts,
        metadata: %{
          rtp: %{
            timestamp: timestamp,
            marker: marker,
            sequence_number: 1,
            ssrc: 12_345,
            payload_type: 96
          }
        }
      }
    end)
  end

  # ===========================================================================
  # Scalability structure
  # ===========================================================================

  @doc "An internally consistent `ScalabilityStructure` struct."
  def scalability_struct do
    gen all(
          n_s <- StreamData.integer(0..7),
          n_g <- StreamData.integer(0..15),
          y_flag <- StreamData.boolean(),
          spatial_layers <- StreamData.list_of(spatial_layer(y_flag), length: n_s + 1),
          pictures <- StreamData.list_of(picture(n_s), length: n_g)
        ) do
      %ScalabilityStructure{
        n_s: n_s,
        n_g: n_g,
        y_flag: y_flag,
        spatial_layers: spatial_layers,
        pictures: pictures
      }
    end
  end

  defp spatial_layer(y_flag) do
    gen all(
          width <- StreamData.integer(1..65_535),
          height <- StreamData.integer(1..65_535),
          frame_rate <- StreamData.integer(0..65_535)
        ) do
      %{width: width, height: height, frame_rate: if(y_flag, do: nil, else: frame_rate)}
    end
  end

  defp picture(n_s) do
    gen all(
          temporal_id <- StreamData.integer(0..7),
          spatial_id <- StreamData.integer(0..3),
          reference_count <- StreamData.integer(0..3),
          p_diffs <- StreamData.list_of(StreamData.integer(0..255), length: n_s + 1)
        ) do
      %{
        temporal_id: temporal_id,
        spatial_id: spatial_id,
        reference_count: reference_count,
        p_diffs: p_diffs
      }
    end
  end

  @doc "A struct whose `n_s` field is out of range."
  def invalid_n_s_struct do
    gen all(base <- scalability_struct(), n_s <- StreamData.integer(8..15)) do
      %{base | n_s: n_s}
    end
  end

  @doc "A struct whose `n_g` field is out of range."
  def invalid_n_g_struct do
    gen all(base <- scalability_struct(), n_g <- StreamData.integer(16..255)) do
      %{base | n_g: n_g}
    end
  end

  @doc "A struct whose spatial-layer count does not match `n_s + 1`."
  def layer_mismatch_struct do
    gen all(base <- scalability_struct()) do
      extra = %{width: 320, height: 240, frame_rate: nil}
      %{base | spatial_layers: [extra | base.spatial_layers]}
    end
  end

  @doc "A struct whose picture count does not match `n_g`."
  def picture_mismatch_struct do
    gen all(base <- scalability_struct()) do
      extra = %{
        temporal_id: 0,
        spatial_id: 0,
        reference_count: 0,
        p_diffs: List.duplicate(0, base.n_s + 1)
      }

      %{base | pictures: [extra | base.pictures]}
    end
  end

  @doc "A binary larger than the maximum scalability structure size."
  def oversized_ss_binary do
    StreamData.binary(min_length: 256, max_length: 400)
  end

  # ===========================================================================
  # Plain helpers
  # ===========================================================================

  @doc "A fresh depayloader state with sequence-header management enabled."
  def fresh_state do
    %State{require_sequence_header: true, max_reorder_buffer: 10}
  end

  @doc "Folds a list of buffers through the depayloader, accumulating all actions."
  def run_depayloader(buffers, state \\ fresh_state()) do
    Enum.reduce(buffers, {[], state}, fn buffer, {actions, current_state} ->
      {new_actions, new_state} = Depayloader.handle_buffer(:input, buffer, %{}, current_state)
      {actions ++ new_actions, new_state}
    end)
  end

  @doc """
  Splits a concatenated temporal unit (every OBU carrying a size field) into a
  list of structured OBU maps. Returns `[]` for any OBU that cannot be walked.
  """
  def split_obus(<<>>), do: []

  def split_obus(data) do
    with {:ok, info} <- Depayloader.parse_obu_header(data),
         true <- info.has_size,
         {:ok, size_bytes, payload_size} <- LEB128.read(info.rest),
         true <- size_bytes + payload_size <= byte_size(info.rest) do
      <<_leb::binary-size(size_bytes), payload::binary-size(payload_size), rest::binary>> =
        info.rest

      [obu_from_header(info, payload) | split_obus(rest)]
    else
      _ -> []
    end
  end

  @doc "Reduces an OBU map to the fields preserved through depayloading."
  def semantic(obu), do: Map.take(obu, @semantic_keys)

  @doc "`semantic/1` for every OBU, excluding temporal delimiters and tile lists."
  def semantics(obus) do
    obus
    |> Enum.reject(&(&1.type in [@obu_temporal_delimiter, @obu_tile_list]))
    |> Enum.map(&semantic/1)
  end

  @doc "The canonical temporal delimiter the depayloader prepends to every output."
  def temporal_delimiter_obu, do: %{type: @obu_temporal_delimiter, payload: <<>>}

  defp build_obu(type, has_extension, has_size, ext_byte, payload) do
    payload = if type == @obu_temporal_delimiter, do: <<>>, else: payload
    extension_flag = if has_extension, do: 1, else: 0
    size_flag = if has_size, do: 1, else: 0
    header = <<0::1, type::4, extension_flag::1, size_flag::1, 0::1>>
    extension = if has_extension, do: <<ext_byte>>, else: <<>>
    size = if has_size, do: LEB128.encode(byte_size(payload)), else: <<>>

    %{
      type: type,
      has_extension: has_extension,
      has_size: has_size,
      temporal_id: if(has_extension, do: ext_byte >>> 5 &&& 0x07, else: nil),
      spatial_id: if(has_extension, do: ext_byte >>> 3 &&& 0x03, else: nil),
      payload: payload,
      bytes: header <> extension <> size <> payload
    }
  end

  defp obu_from_header(info, payload) do
    %{
      type: info.type,
      has_extension: info.has_extension,
      temporal_id: info.extension && info.extension.temporal_id,
      spatial_id: info.extension && info.extension.spatial_id,
      payload: payload
    }
  end

  defp split_into(binary, 1), do: [binary]

  defp split_into(binary, pieces) do
    chunk = max(1, div(byte_size(binary), pieces))
    take = min(chunk, byte_size(binary) - (pieces - 1))
    <<head::binary-size(take), rest::binary>> = binary
    [head | split_into(rest, pieces - 1)]
  end
end
