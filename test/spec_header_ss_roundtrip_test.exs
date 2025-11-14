defmodule Membrane.RTP.AV1.SpecHeaderSSRoundTripTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.Payloader
  alias Membrane.RTP.AV1.Depayloader
  alias Membrane.RTP.AV1.OBU
  alias Membrane.Buffer

  test "round-trip with :spec header_mode and SS data passthrough" do
    obu1 = OBU.build_obu(:crypto.strong_rand_bytes(256))
    obu2 = OBU.build_obu(:crypto.strong_rand_bytes(900))
    access_unit = IO.iodata_to_binary([obu1, obu2])
    pts = 3_000_000

    ss_data = <<1, 2, 3, 4, 5, 6>> # minimal placeholder SS data

    {_actions, pstate} =
      Payloader.handle_init(nil, %{
        mtu: 800,
        payload_type: 96,
        clock_rate: 90_000,
        header_mode: :spec,
        fmtp: %{ss_data: Base.encode16(ss_data)}
      })

    {_sf_actions, pstate} = Payloader.handle_stream_format(:input, :any, nil, pstate)
    {actions, _} = Payloader.handle_buffer(:input, %Buffer{payload: access_unit, pts: pts}, nil, pstate)

    rtp_buffers =
      for {:buffer, {_pad_ref, buffer}} <- actions, do: buffer

    {_dactions, dstate} =
      Depayloader.handle_init(nil, %{clock_rate: 90_000, header_mode: :spec, fmtp: %{}})

    {_dsf_actions, dstate} =
      Depayloader.handle_stream_format(:input, %Membrane.RTP{payload_format: nil}, nil, dstate)

    {out, _} =
      Enum.reduce(rtp_buffers, {[], dstate}, fn buffer, {acc, st} ->
        {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
        {acc ++ acts, st2}
      end)

    out_buffers =
      for {:buffer, {_pad_ref, buffer}} <- out, do: buffer

    assert length(out_buffers) == 1
    assert [%Buffer{payload: ^access_unit, pts: ^pts}] = out_buffers
  end
end

