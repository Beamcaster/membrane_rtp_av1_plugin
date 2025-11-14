defmodule Membrane.RTP.AV1.WBitIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{Depayloader, FullHeader}
  alias Membrane.Buffer
  import Membrane.RTP.AV1.TestHelperUtils

  describe "depayloader with W-bit validation" do
    test "accepts standalone packets (W=0)" do
      {:ok, state} = init_depayloader()

      # Send three standalone packets
      payload1 = encode_full_header(0, true, false, 1) <> <<1, 2, 3>>
      payload2 = encode_full_header(0, true, false, 1) <> <<4, 5, 6>>
      payload3 = encode_full_header(0, true, false, 1) <> <<7, 8, 9>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      {actions, _state} = handle_buffer(state, payload3, 3000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4, 5, 6, 7, 8, 9>>
    end

    test "accepts valid fragment sequence W=1 → W=3" do
      {:ok, state} = init_depayloader()

      # First fragment
      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2, 3>>
      # Last fragment
      payload2 = encode_full_header(3, false, false, 1) <> <<4, 5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {actions, _state} = handle_buffer(state, payload2, 2000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4, 5, 6>>
    end

    test "accepts valid fragment sequence W=1 → W=2 → W=3" do
      {:ok, state} = init_depayloader()

      # First fragment
      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2>>
      # Middle fragment
      payload2 = encode_full_header(2, false, false, 1) <> <<3, 4>>
      # Last fragment
      payload3 = encode_full_header(3, false, false, 1) <> <<5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      {actions, _state} = handle_buffer(state, payload3, 3000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4, 5, 6>>
    end

    test "accepts valid fragment sequence W=1 → W=2 → W=2 → W=3" do
      {:ok, state} = init_depayloader()

      payload1 = encode_full_header(1, true, false, 1) <> <<1>>
      payload2 = encode_full_header(2, false, false, 1) <> <<2>>
      payload3 = encode_full_header(2, false, false, 1) <> <<3>>
      payload4 = encode_full_header(3, false, false, 1) <> <<4>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      {[], state} = handle_buffer(state, payload3, 3000, false)
      {actions, _state} = handle_buffer(state, payload4, 4000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4>>
    end

    test "rejects W=2 without prior W=1" do
      {:ok, state} = init_depayloader()

      # Try to send W=2 without W=1
      payload = encode_full_header(2, false, false, 1) <> <<1, 2, 3>>

      # Should reset and discard
      {[], state} = handle_buffer(state, payload, 1000, false)

      # Verify state was reset (acc and frag_acc should be empty)
      # Zero-copy: acc and frag_acc are now IO lists
      assert state.acc == []
      assert state.frag_acc == []
    end

    test "rejects W=3 without prior W=1" do
      {:ok, state} = init_depayloader()

      payload = encode_full_header(3, false, false, 1) <> <<1, 2, 3>>

      {[], state} = handle_buffer(state, payload, 1000, false)

      assert state.acc == []
      assert state.frag_acc == []
    end

    test "rejects W=0 after W=1 (incomplete fragment)" do
      {:ok, state} = init_depayloader()

      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2, 3>>
      payload2 = encode_full_header(0, true, false, 1) <> <<4, 5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      # This should reset state
      {[], state} = handle_buffer(state, payload2, 2000, false)

      assert state.acc == []
      assert state.frag_acc == []
    end

    test "rejects W=1 after W=1 (double start)" do
      {:ok, state} = init_depayloader()

      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2, 3>>
      payload2 = encode_full_header(1, true, false, 1) <> <<4, 5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)

      assert state.acc == []
      assert state.frag_acc == []
    end

    test "accepts multiple complete fragment sequences" do
      {:ok, state} = init_depayloader()

      # First fragment sequence W=1→W=3
      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2>>
      payload2 = encode_full_header(3, false, false, 1) <> <<3, 4>>

      # Second fragment sequence W=1→W=2→W=3
      payload3 = encode_full_header(1, true, false, 1) <> <<5>>
      payload4 = encode_full_header(2, false, false, 1) <> <<6>>
      payload5 = encode_full_header(3, false, false, 1) <> <<7>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      {[], state} = handle_buffer(state, payload3, 3000, false)
      {[], state} = handle_buffer(state, payload4, 4000, false)
      {actions, _state} = handle_buffer(state, payload5, 5000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4, 5, 6, 7>>
    end

    test "accepts mixed standalone and fragments" do
      {:ok, state} = init_depayloader()

      # Standalone
      payload1 = encode_full_header(0, true, false, 1) <> <<1, 2>>
      # Fragment sequence
      payload2 = encode_full_header(1, true, false, 1) <> <<3>>
      payload3 = encode_full_header(3, false, false, 1) <> <<4>>
      # Standalone
      payload4 = encode_full_header(0, true, false, 1) <> <<5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      {[], state} = handle_buffer(state, payload3, 3000, false)
      {actions, _state} = handle_buffer(state, payload4, 4000, true)
      buffer = first_output_buffer(actions)

      assert buffer.payload == <<1, 2, 3, 4, 5, 6>>
    end

    test "recovers after invalid transition" do
      {:ok, state} = init_depayloader()

      # Start valid fragment
      payload1 = encode_full_header(1, true, false, 1) <> <<1, 2>>
      # Invalid: W=0 interrupts fragment
      payload2 = encode_full_header(0, true, false, 1) <> <<99>>
      # Start new valid fragment
      payload3 = encode_full_header(1, true, false, 1) <> <<3, 4>>
      payload4 = encode_full_header(3, false, false, 1) <> <<5, 6>>

      {[], state} = handle_buffer(state, payload1, 1000, false)
      {[], state} = handle_buffer(state, payload2, 2000, false)
      # State should be reset, start fresh
      {[], state} = handle_buffer(state, payload3, 3000, false)
      {actions, _state} = handle_buffer(state, payload4, 4000, true)
      buffer = first_output_buffer(actions)

      # Should only have data from valid sequence (3,4,5,6), not incomplete (1,2)
      assert buffer.payload == <<3, 4, 5, 6>>
    end
  end

  # Helper functions

  defp init_depayloader do
    opts = %{
      clock_rate: 90_000,
      fmtp: %{},
      header_mode: :spec
    }

    {[], state} = Depayloader.handle_init(nil, opts)
    {:ok, state}
  end

  defp handle_buffer(state, payload, pts, marker) do
    metadata = %{rtp: %{marker: marker}}
    buffer = %Buffer{payload: payload, pts: pts, metadata: metadata}
    Depayloader.handle_buffer(:input, buffer, nil, state)
  end

  defp encode_full_header(w, y, z, obu_count) do
    header = %FullHeader{
      z: z,
      y: y,
      w: w,
      n: obu_count > 1,
      c: obu_count,
      m: false
    }

    FullHeader.encode(header)
  end
end
