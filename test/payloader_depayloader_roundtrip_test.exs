defmodule Membrane.RTP.AV1.RoundTripTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.Payloader
  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.Buffer

  test "simple round-trip by splitting and reassembling" do
    # Build an access unit consisting of multiple OBUs with various sizes
    small = :crypto.strong_rand_bytes(500)
    medium = :crypto.strong_rand_bytes(5_000)
    tiny = :crypto.strong_rand_bytes(300)

    obu_small = Membrane.RTP.AV1.OBU.build_obu(small)
    obu_medium = Membrane.RTP.AV1.OBU.build_obu(medium)
    obu_tiny = Membrane.RTP.AV1.OBU.build_obu(tiny)

    access_unit = IO.iodata_to_binary([obu_small, obu_medium, obu_tiny])
    pts = 1_000_000

    # Simulate payloader
    {_actions, pstate} = Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, clock_rate: 90_000})
    {_sf_actions, pstate} = Payloader.handle_stream_format(:input, :any, nil, pstate)
    {actions, _} = Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: pts}, nil, pstate)

    # Extract RTP-like buffers
    rtp_buffers =
      actions
      |> Enum.flat_map(fn
        {:buffer, {_pad_ref, buffer}} -> [buffer]
        _ -> []
      end)

    # Simulate depayloader
    {_dactions, dstate} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
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
