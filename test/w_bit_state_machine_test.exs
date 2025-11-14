defmodule Membrane.RTP.AV1.WBitStateMachineTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.WBitStateMachine

  describe "new/0" do
    test "creates state machine in idle state" do
      sm = WBitStateMachine.new()
      assert sm.state == :idle
      assert sm.last_w == nil
    end
  end

  describe "next/2 - standalone packets (W=0)" do
    test "accepts initial W=0" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert sm.state == :idle
      assert sm.last_w == 0
    end

    test "accepts consecutive W=0 packets" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert sm.state == :idle
      assert sm.last_w == 0
    end

    test "rejects W=0 after W=1 (incomplete fragment)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:error, :incomplete_fragment} = WBitStateMachine.next(sm, 0)
    end

    test "rejects W=0 after W=2 (incomplete fragment)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:error, :incomplete_fragment} = WBitStateMachine.next(sm, 0)
    end

    test "accepts W=0 after W=3 (fragment complete)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert sm.state == :idle
    end
  end

  describe "next/2 - fragment sequences" do
    test "accepts W=1 as initial fragment start" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert sm.state == :in_fragment
      assert sm.last_w == 1
    end

    test "accepts W=1 after W=0 (start new fragment)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert sm.state == :in_fragment
    end

    test "accepts W=1 after W=3 (start new fragment)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert sm.state == :in_fragment
    end

    test "rejects W=1 after W=1 (double start)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:error, :incomplete_fragment} = WBitStateMachine.next(sm, 1)
    end

    test "rejects W=1 after W=2 (restart mid-fragment)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:error, :incomplete_fragment} = WBitStateMachine.next(sm, 1)
    end
  end

  describe "next/2 - middle fragments (W=2)" do
    test "accepts W=2 after W=1" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert sm.state == :in_fragment
      assert sm.last_w == 2
    end

    test "accepts W=2 after W=2 (multiple middle fragments)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert sm.state == :in_fragment
    end

    test "rejects W=2 as initial packet" do
      sm = WBitStateMachine.new()
      assert {:error, :fragment_not_started} = WBitStateMachine.next(sm, 2)
    end

    test "rejects W=2 after W=0 (no fragment started)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:error, :fragment_not_started} = WBitStateMachine.next(sm, 2)
    end

    test "rejects W=2 after W=3 (fragment already complete)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:error, :invalid_w_transition} = WBitStateMachine.next(sm, 2)
    end
  end

  describe "next/2 - last fragments (W=3)" do
    test "accepts W=3 after W=1 (single fragment OBU)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert sm.state == :idle
      assert sm.last_w == 3
    end

    test "accepts W=3 after W=2" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert sm.state == :idle
    end

    test "rejects W=3 as initial packet" do
      sm = WBitStateMachine.new()
      assert {:error, :fragment_not_started} = WBitStateMachine.next(sm, 3)
    end

    test "rejects W=3 after W=0 (no fragment started)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:error, :fragment_not_started} = WBitStateMachine.next(sm, 3)
    end

    test "rejects W=3 after W=3 (double end)" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:error, :invalid_w_transition} = WBitStateMachine.next(sm, 3)
    end
  end

  describe "next/2 - complex sequences" do
    test "accepts valid sequence: W=1 → W=2 → W=2 → W=3" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert sm.state == :idle
    end

    test "accepts valid sequence: W=0 → W=1 → W=3 → W=0" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert sm.state == :idle
    end

    test "accepts multiple fragment sequences: W=1→3, W=1→2→3, W=1→3" do
      sm = WBitStateMachine.new()
      # First fragment
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      # Second fragment
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      # Third fragment
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert sm.state == :idle
    end

    test "accepts mixed standalone and fragments: W=0 → W=0 → W=1 → W=3 → W=0" do
      sm = WBitStateMachine.new()
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, sm} = WBitStateMachine.next(sm, 3)
      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert sm.state == :idle
    end
  end

  describe "next/2 - invalid values" do
    test "rejects W values outside 0-3" do
      sm = WBitStateMachine.new()
      assert {:error, :invalid_w_value} = WBitStateMachine.next(sm, -1)
      assert {:error, :invalid_w_value} = WBitStateMachine.next(sm, 4)
      assert {:error, :invalid_w_value} = WBitStateMachine.next(sm, 255)
    end
  end

  describe "reset/1" do
    test "resets state machine to idle from idle" do
      sm = WBitStateMachine.new()
      sm = WBitStateMachine.reset(sm)
      assert sm.state == :idle
      assert sm.last_w == nil
    end

    test "resets state machine to idle from in_fragment" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert sm.state == :in_fragment

      sm = WBitStateMachine.reset(sm)
      assert sm.state == :idle
      assert sm.last_w == nil
    end

    test "can continue normal operation after reset" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 1)
      {:ok, sm} = WBitStateMachine.next(sm, 2)

      sm = WBitStateMachine.reset(sm)

      assert {:ok, sm} = WBitStateMachine.next(sm, 0)
      assert {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert {:ok, _sm} = WBitStateMachine.next(sm, 3)
    end
  end

  describe "incomplete_fragment?/1" do
    test "returns false for new state machine" do
      sm = WBitStateMachine.new()
      refute WBitStateMachine.incomplete_fragment?(sm)
    end

    test "returns false after W=0" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 0)
      refute WBitStateMachine.incomplete_fragment?(sm)
    end

    test "returns true after W=1" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 1)
      assert WBitStateMachine.incomplete_fragment?(sm)
    end

    test "returns true after W=2" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 1)
      {:ok, sm} = WBitStateMachine.next(sm, 2)
      assert WBitStateMachine.incomplete_fragment?(sm)
    end

    test "returns false after W=3 (fragment complete)" do
      sm = WBitStateMachine.new()
      {:ok, sm} = WBitStateMachine.next(sm, 1)
      {:ok, sm} = WBitStateMachine.next(sm, 3)
      refute WBitStateMachine.incomplete_fragment?(sm)
    end
  end

  describe "error_message/1" do
    test "returns message for invalid_w_transition" do
      msg = WBitStateMachine.error_message({:error, :invalid_w_transition})
      assert msg =~ "Invalid W-bit transition"
      assert msg =~ "W=1→W=2*→W=3"
    end

    test "returns message for fragment_not_started" do
      msg = WBitStateMachine.error_message({:error, :fragment_not_started})
      assert msg =~ "Fragment not started"
      assert msg =~ "W=2 or W=3 requires prior W=1"
    end

    test "returns message for incomplete_fragment" do
      msg = WBitStateMachine.error_message({:error, :incomplete_fragment})
      assert msg =~ "Incomplete fragment"
      assert msg =~ "W=0 cannot follow W=1 or W=2"
    end

    test "returns message for invalid_w_value" do
      msg = WBitStateMachine.error_message({:error, :invalid_w_value})
      assert msg =~ "W value must be 0, 1, 2, or 3"
    end

    test "returns generic message for unknown error" do
      msg = WBitStateMachine.error_message({:error, :unknown})
      assert msg =~ "Unknown W-bit state machine error"
    end
  end
end
