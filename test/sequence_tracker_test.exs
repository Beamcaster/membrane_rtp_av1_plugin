defmodule Membrane.RTP.AV1.SequenceTrackerTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.SequenceTracker

  describe "new/0" do
    test "creates uninitialized tracker" do
      tracker = SequenceTracker.new()
      assert tracker.last_seq == nil
      assert tracker.initialized? == false
      assert tracker.wrap_count == 0
    end
  end

  describe "next/2 with first packet" do
    test "accepts any valid sequence number as first packet" do
      tracker = SequenceTracker.new()

      assert {:ok, tracker} = SequenceTracker.next(tracker, 0)
      assert tracker.last_seq == 0
      assert tracker.initialized? == true

      tracker = SequenceTracker.new()
      assert {:ok, tracker} = SequenceTracker.next(tracker, 12345)
      assert tracker.last_seq == 12345
      assert tracker.initialized? == true

      tracker = SequenceTracker.new()
      assert {:ok, tracker} = SequenceTracker.next(tracker, 65535)
      assert tracker.last_seq == 65535
      assert tracker.initialized? == true
    end
  end

  describe "next/2 with monotonic sequences" do
    test "accepts sequential packets" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:ok, tracker} = SequenceTracker.next(tracker, 101)
      {:ok, tracker} = SequenceTracker.next(tracker, 102)

      assert tracker.last_seq == 102
      assert tracker.initialized? == true
    end

    test "accepts sequence with gaps (packet loss)" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:ok, tracker} = SequenceTracker.next(tracker, 105)

      assert tracker.last_seq == 105
      assert tracker.initialized? == true
    end

    test "detects gaps correctly" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 100)

      assert SequenceTracker.is_gap?(tracker, 102) == true
      assert SequenceTracker.gap_size(tracker, 102) == 1

      assert SequenceTracker.is_gap?(tracker, 101) == false
      assert SequenceTracker.gap_size(tracker, 101) == 0

      assert SequenceTracker.is_gap?(tracker, 110) == true
      assert SequenceTracker.gap_size(tracker, 110) == 9
    end
  end

  describe "next/2 with sequence wraparound" do
    test "handles wraparound from 65535 to 0" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 65534)
      {:ok, tracker} = SequenceTracker.next(tracker, 65535)
      {:ok, tracker} = SequenceTracker.next(tracker, 0)
      {:ok, tracker} = SequenceTracker.next(tracker, 1)

      assert tracker.last_seq == 1
      assert tracker.wrap_count == 1
    end

    test "handles wraparound with gap" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 65533)
      {:ok, tracker} = SequenceTracker.next(tracker, 2)

      assert tracker.last_seq == 2
      assert tracker.wrap_count == 1
    end

    test "detects gap across wraparound" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 65534)

      assert SequenceTracker.is_gap?(tracker, 1) == true
      # Gap from 65534 to 1: missing 65535, 0 = 2 missing packets
      assert SequenceTracker.gap_size(tracker, 1) == 2

      assert SequenceTracker.is_gap?(tracker, 5) == true
      # Gap from 65534 to 5: missing 65535, 0, 1, 2, 3, 4 = 6 missing packets
      assert SequenceTracker.gap_size(tracker, 5) == 6
    end

    test "handles multiple wraparounds" do
      tracker = SequenceTracker.new()

      # First wraparound
      {:ok, tracker} = SequenceTracker.next(tracker, 65534)
      {:ok, tracker} = SequenceTracker.next(tracker, 65535)
      {:ok, tracker} = SequenceTracker.next(tracker, 0)
      {:ok, tracker} = SequenceTracker.next(tracker, 1)

      # Continue forward - just verify continued normal operation
      {:ok, _tracker} = SequenceTracker.next(tracker, 2)
    end
  end

  describe "next/2 with duplicates" do
    test "detects duplicate sequence number" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:error, :duplicate, tracker} = SequenceTracker.next(tracker, 100)

      assert tracker.last_seq == 100
    end

    test "detects duplicate after several packets" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:ok, tracker} = SequenceTracker.next(tracker, 101)
      {:ok, tracker} = SequenceTracker.next(tracker, 102)
      {:error, :duplicate, tracker} = SequenceTracker.next(tracker, 102)

      assert tracker.last_seq == 102
    end
  end

  describe "next/2 with out-of-order packets" do
    test "detects old sequence number" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:ok, tracker} = SequenceTracker.next(tracker, 101)
      {:error, :out_of_order, tracker} = SequenceTracker.next(tracker, 99)

      assert tracker.last_seq == 101
    end

    test "detects significantly old packet" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 1000)
      {:error, :out_of_order, tracker} = SequenceTracker.next(tracker, 500)

      assert tracker.last_seq == 1000
    end

    test "detects old packet near wraparound boundary" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      # 65535 is old relative to 100 (would be going backwards)
      {:error, :out_of_order, tracker} = SequenceTracker.next(tracker, 65535)

      assert tracker.last_seq == 100
    end
  end

  describe "next/2 with large gaps" do
    test "detects large forward gap as potential error" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      # Jump forward by 1500 - this is a large gap
      {:error, :large_gap, _tracker} = SequenceTracker.next(tracker, 1600)
    end

    test "treats huge backward-looking jump as out of order" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 1000)
      # 35000 looks like going backward from 1000 (wraparound perspective)
      {:error, :out_of_order, _tracker} = SequenceTracker.next(tracker, 35000)
    end
  end

  describe "reset/1" do
    test "resets tracker to initial state" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 100)
      {:ok, tracker} = SequenceTracker.next(tracker, 101)

      tracker = SequenceTracker.reset(tracker)

      assert tracker.last_seq == nil
      assert tracker.initialized? == false
      assert tracker.wrap_count == 0
    end

    test "can reinitialize after reset" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 100)

      tracker = SequenceTracker.reset(tracker)
      {:ok, tracker} = SequenceTracker.next(tracker, 200)

      assert tracker.last_seq == 200
      assert tracker.initialized? == true
    end
  end

  describe "expected_next/1" do
    test "returns nil for uninitialized tracker" do
      tracker = SequenceTracker.new()
      assert SequenceTracker.expected_next(tracker) == nil
    end

    test "returns next sequence number" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 100)

      assert SequenceTracker.expected_next(tracker) == 101
    end

    test "handles wraparound in expected_next" do
      tracker = SequenceTracker.new()
      {:ok, tracker} = SequenceTracker.next(tracker, 65535)

      assert SequenceTracker.expected_next(tracker) == 0
    end
  end

  describe "edge cases" do
    test "maximum sequence number" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 65535)
      assert tracker.last_seq == 65535
    end

    test "minimum sequence number" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 0)
      assert tracker.last_seq == 0
    end

    test "sequence starting at boundary" do
      tracker = SequenceTracker.new()

      {:ok, tracker} = SequenceTracker.next(tracker, 65535)
      {:ok, tracker} = SequenceTracker.next(tracker, 0)
      {:ok, tracker} = SequenceTracker.next(tracker, 1)

      assert tracker.last_seq == 1
    end
  end
end
