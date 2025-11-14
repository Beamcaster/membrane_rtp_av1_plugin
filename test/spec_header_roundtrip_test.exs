defmodule Membrane.RTP.AV1.SpecHeaderRoundTripTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.Payloader
  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.Buffer
  alias Membrane.RTP.AV1.OBU

  test "round-trip with :spec header_mode" do
    # AU with OBUs including one that must be fragmented
    small = :crypto.strong_rand_bytes(300)
    large = :crypto.strong_rand_bytes(3000)
    obu_small = OBU.build_obu(small)
    obu_large = OBU.build_obu(large)
    access_unit = IO.iodata_to_binary([obu_small, obu_large])
    pts = 2_000_000

    # Payloader with small MTU to force fragmentation
    {_actions, pstate} =
      Payloader.handle_init(nil, %{mtu: 600, payload_type: 96, clock_rate: 90_000, header_mode: :spec})

    {_sf_actions, pstate} = Payloader.handle_stream_format(:input, :any, nil, pstate)
    {actions, _} = Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: pts}, nil, pstate)

    rtp_buffers =
      actions
      |> Enum.flat_map(fn
        {:buffer, {_pad_ref, buffer}} -> [buffer]
        _ -> []
      end)

    {_dactions, dstate} = Depayloader.handle_init(nil, %{clock_rate: 90_000, header_mode: :spec})
    {_dsf_actions, dstate} = Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, dstate)

    {out, _} =
      Enum.reduce(rtp_buffers, {[], dstate}, fn buffer, {acc, st} ->
        {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
        {acc ++ acts, st2}
      end)

    out_buffers =
      out
      |> Enum.flat_map(fn
        {:buffer, {_pad_ref, buffer}} -> [buffer]
        _ -> []
      end)

    assert length(out_buffers) == 1
    assert [%Buffer{payload: ^access_unit, pts: ^pts}] = out_buffers
  end
end
