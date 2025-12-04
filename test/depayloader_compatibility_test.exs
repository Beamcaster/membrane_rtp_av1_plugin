defmodule Membrane.RTP.AV1.DepayloaderCompatibilityTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP
  alias Membrane.RTP.AV1.{Depayloader, Header}

  defp init_depayloader(opts \\ %{}) do
    opts = Map.merge(%{clock_rate: 90_000}, Map.new(opts))
    {_actions, state} = Depayloader.handle_init(nil, opts)

    {_sf_actions, state} =
      Depayloader.handle_stream_format(:input, %RTP{payload_format: nil}, nil, state)

    state
  end

  defp build_buffer(header, payload, sequence_number, opts \\ []) do
    marker = Keyword.get(opts, :marker, true)
    pts = Keyword.get(opts, :pts, sequence_number)
    metadata = %{rtp: %{marker: marker, sequence_number: sequence_number}}
    %Buffer{payload: Header.encode(header) <> payload, pts: pts, metadata: metadata}
  end

  test "isolated W=3 packet requires compatibility flag" do
    # W=3 is fragment_end (Z=1, Y=0)
    header = Header.fragment_end()
    payload = <<1, 2, 3, 4>>
    buffer = build_buffer(header, payload, 1)

    state = init_depayloader()
    {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)
    assert [] == Enum.filter(actions, &match?({:buffer, _}, &1))

    state = init_depayloader(%{w_compatibility_mode: true})
    {actions, _state} = Depayloader.handle_buffer(:input, buffer, nil, state)
    buffers = Enum.filter(actions, &match?({:buffer, _}, &1))
    assert [{:buffer, {_pad, %Buffer{payload: ^payload}}}] = buffers
  end

  test "dangling fragment is cleared when new W=1 arrives in compatibility mode" do
    # W=1 is fragment_start (Z=0, Y=1)
    start_header = Header.fragment_start(false)
    # W=3 is fragment_end (Z=1, Y=0)
    end_header = Header.fragment_end()
    stale = <<0, 1, 2>>
    fresh = <<3, 4, 5>>
    tail = <<6, 7>>

    state = init_depayloader(%{w_compatibility_mode: true})

    {_, state} =
      Depayloader.handle_buffer(
        :input,
        build_buffer(start_header, stale, 10, marker: false, pts: 100),
        nil,
        state
      )

    {_, state} =
      Depayloader.handle_buffer(
        :input,
        build_buffer(start_header, fresh, 11, marker: false, pts: 200),
        nil,
        state
      )

    {actions, _state} =
      Depayloader.handle_buffer(
        :input,
        build_buffer(end_header, tail, 12, marker: true, pts: 300),
        nil,
        state
      )

    expected_payload = fresh <> tail
    buffers = Enum.filter(actions, &match?({:buffer, _}, &1))
    assert [{:buffer, {_pad, %Buffer{payload: ^expected_payload}}}] = buffers
  end

  test "standalone W=0 after fragment flushes stale data in compatibility mode" do
    # W=1 is fragment_start (Z=0, Y=1)
    start_header = Header.fragment_start(false)
    # W=0 is complete (Z=0, Y=0)
    standalone_header = Header.complete(0, false)
    stale = <<0, 1, 2>>
    fresh = <<9, 8, 7>>

    state = init_depayloader(%{w_compatibility_mode: true})

    {_, state} =
      Depayloader.handle_buffer(
        :input,
        build_buffer(start_header, stale, 20, marker: false, pts: 10),
        nil,
        state
      )

    {actions, _state} =
      Depayloader.handle_buffer(
        :input,
        build_buffer(standalone_header, fresh, 21, marker: true, pts: 30),
        nil,
        state
      )

    assert [{:buffer, {_pad, %Buffer{payload: ^fresh}}}] =
             Enum.filter(actions, &match?({:buffer, _}, &1))
  end
end
