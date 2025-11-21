defmodule Membrane.RTP.AV1.ExWebRTC.Payload do
  @moduledoc false
  # AV1 RTP payload structure parsing and serialization.
  # Adapted from ExWebRTC.RTP.AV1.Payload
  #
  # Based on [RTP Payload Format for AV1](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html).
  #
  #  RTP payload syntax:
  #      0 1 2 3 4 5 6 7
  #     +-+-+-+-+-+-+-+-+
  #     |Z|Y| W |N|-|-|-| (REQUIRED)
  #     +=+=+=+=+=+=+=+=+

  @type t :: %__MODULE__{
          z: 0 | 1,
          y: 0 | 1,
          w: 0 | 1 | 2 | 3,
          n: 0 | 1,
          payload: binary()
        }

  @enforce_keys [:z, :y, :w, :n, :payload]
  defstruct @enforce_keys ++ []

  @doc """
  Parses RTP payload as AV1 payload.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_packet}
  def parse(rtp_payload)

  def parse(<<z::1, y::1, w::2, n::1, 0::3, payload::binary>>) do
    if payload == <<>> do
      {:error, :invalid_packet}
    else
      {:ok,
       %__MODULE__{
         z: z,
         y: y,
         w: w,
         n: n,
         payload: payload
       }}
    end
  end

  def parse(_), do: {:error, :invalid_packet}

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{
        z: z,
        y: y,
        w: w,
        n: n,
        payload: payload
      }) do
    <<z::1, y::1, w::2, n::1, 0::3, payload::binary>>
  end

  @doc """
  Payloads chunked fragments of single OBU and sets Z, Y bits.
  """
  @spec payload_obu_fragments([binary()], 0 | 1) :: [t()]
  def payload_obu_fragments(obu_fragments, n_bit \\ 0)

  def payload_obu_fragments([entire_obu], n_bit) do
    [%__MODULE__{z: 0, y: 0, w: 1, n: n_bit, payload: entire_obu}]
  end

  def payload_obu_fragments([first_obu_fragment | next_obu_fragments], n_bit) do
    # First fragment of OBU: set Y bit
    first_obu_payload = %__MODULE__{z: 0, y: 1, w: 1, n: n_bit, payload: first_obu_fragment}

    next_obu_payloads =
      next_obu_fragments
      # Middle fragments of OBU: set Z, Y bits
      |> Enum.map(&%__MODULE__{z: 1, y: 1, w: 1, n: 0, payload: &1})
      # Last fragment of OBU: set Z bit only (unset Y)
      |> List.update_at(-1, &%{&1 | y: 0})

    [first_obu_payload | next_obu_payloads]
  end
end
