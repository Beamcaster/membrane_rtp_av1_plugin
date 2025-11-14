defmodule Membrane.RTP.AV1.SequenceTracker do
  @moduledoc """
  Tracks RTP sequence numbers to detect out-of-order packets and duplicates.

  RTP sequence numbers are 16-bit values that wrap around from 65535 to 0.
  This module handles:
  - Monotonic sequence validation
  - Duplicate detection
  - Sequence number wraparound
  - Gap detection for packet loss
  """

  @max_seq_num 65535
  @seq_diff_threshold 32768
  @large_gap_threshold 1000

  @typedoc """
  State for tracking sequence numbers.

  - `last_seq`: The last valid sequence number received
  - `initialized?`: Whether we've received the first packet
  - `wrap_count`: Number of times sequence has wrapped around (for debugging)
  """
  @type t :: %__MODULE__{
          last_seq: non_neg_integer() | nil,
          initialized?: boolean(),
          wrap_count: non_neg_integer()
        }

  defstruct last_seq: nil,
            initialized?: false,
            wrap_count: 0

  @doc """
  Creates a new sequence tracker.

  ## Examples

      iex> SequenceTracker.new()
      %SequenceTracker{last_seq: nil, initialized?: false, wrap_count: 0}
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Validates and updates sequence number tracking.

  Returns:
  - `{:ok, new_tracker}` - sequence is valid (first packet or monotonically increasing)
  - `{:error, :duplicate, tracker}` - duplicate sequence number
  - `{:error, :out_of_order, tracker}` - sequence number is older than expected
  - `{:error, :large_gap, tracker}` - gap indicates potential sequence wraparound issue

  ## Examples

      iex> tracker = SequenceTracker.new()
      iex> {:ok, tracker} = SequenceTracker.next(tracker, 100)
      iex> {:ok, tracker} = SequenceTracker.next(tracker, 101)
      iex> {:error, :duplicate, _tracker} = SequenceTracker.next(tracker, 101)
  """
  @spec next(t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :duplicate | :out_of_order | :large_gap, t()}
  def next(%__MODULE__{initialized?: false} = tracker, seq_num)
      when seq_num >= 0 and seq_num <= @max_seq_num do
    # First packet - accept any sequence number
    {:ok, %{tracker | last_seq: seq_num, initialized?: true}}
  end

  def next(%__MODULE__{last_seq: last_seq} = tracker, seq_num)
      when seq_num >= 0 and seq_num <= @max_seq_num do
    cond do
      # Duplicate
      seq_num == last_seq ->
        {:error, :duplicate, tracker}

      # Normal increment (including small wraparound)
      is_next_sequence?(last_seq, seq_num) ->
        diff = sequence_diff(seq_num, last_seq)

        # Check if gap is very large (likely indicates an issue)
        if diff > @large_gap_threshold and diff < @seq_diff_threshold do
          {:error, :large_gap, tracker}
        else
          wrap_count =
            if seq_num < last_seq, do: tracker.wrap_count + 1, else: tracker.wrap_count

          {:ok, %{tracker | last_seq: seq_num, wrap_count: wrap_count}}
        end

      # Out of order (older packet)
      is_older_sequence?(last_seq, seq_num) ->
        {:error, :out_of_order, tracker}

      # Should not reach here with current logic
      true ->
        {:error, :out_of_order, tracker}
    end
  end

  @doc """
  Resets the sequence tracker to initial state.

  Useful when recovering from errors or starting a new stream.

  ## Examples

      iex> tracker = %SequenceTracker{last_seq: 100, initialized?: true}
      iex> SequenceTracker.reset(tracker)
      %SequenceTracker{last_seq: nil, initialized?: false, wrap_count: 0}
  """
  @spec reset(t()) :: t()
  def reset(_tracker) do
    new()
  end

  @doc """
  Returns the expected next sequence number.

  Returns `nil` if no packets have been received yet.

  ## Examples

      iex> tracker = %SequenceTracker{last_seq: 100, initialized?: true}
      iex> SequenceTracker.expected_next(tracker)
      101
      
      iex> tracker = %SequenceTracker{last_seq: 65535, initialized?: true}
      iex> SequenceTracker.expected_next(tracker)
      0
  """
  @spec expected_next(t()) :: non_neg_integer() | nil
  def expected_next(%__MODULE__{initialized?: false}), do: nil
  def expected_next(%__MODULE__{last_seq: last_seq}), do: rem(last_seq + 1, @max_seq_num + 1)

  @doc """
  Checks if a sequence number represents a gap (packet loss).

  ## Examples

      iex> tracker = %SequenceTracker{last_seq: 100, initialized?: true}
      iex> SequenceTracker.is_gap?(tracker, 102)
      true
      
      iex> SequenceTracker.is_gap?(tracker, 101)
      false
  """
  @spec is_gap?(t(), non_neg_integer()) :: boolean()
  def is_gap?(%__MODULE__{initialized?: false}, _seq_num), do: false

  def is_gap?(%__MODULE__{last_seq: last_seq}, seq_num) do
    expected = rem(last_seq + 1, @max_seq_num + 1)
    is_next_sequence?(last_seq, seq_num) and seq_num != expected
  end

  @doc """
  Calculates the gap size (number of missing packets).

  Returns 0 if no gap.

  ## Examples

      iex> tracker = %SequenceTracker{last_seq: 100, initialized?: true}
      iex> SequenceTracker.gap_size(tracker, 103)
      2
      
      iex> SequenceTracker.gap_size(tracker, 101)
      0
  """
  @spec gap_size(t(), non_neg_integer()) :: non_neg_integer()
  def gap_size(%__MODULE__{initialized?: false}, _seq_num), do: 0

  def gap_size(%__MODULE__{last_seq: last_seq}, seq_num) do
    diff = sequence_diff(seq_num, last_seq)

    cond do
      # No gap if next in sequence or older
      diff <= 1 -> 0
      # Gap exists - return number of missing packets
      diff > 1 and diff < @seq_diff_threshold -> diff - 1
      # No gap for out of order or very large jumps
      true -> 0
    end
  end

  # Private helpers

  # Check if seq_num is the next expected sequence (allowing wraparound)
  defp is_next_sequence?(last_seq, seq_num) do
    diff = sequence_diff(seq_num, last_seq)
    diff > 0 and diff < @seq_diff_threshold
  end

  # Check if seq_num is older than last_seq (accounting for wraparound)
  defp is_older_sequence?(last_seq, seq_num) do
    diff = sequence_diff(seq_num, last_seq)
    diff < 0 or diff >= @seq_diff_threshold
  end

  # Calculate signed difference between sequence numbers, handling wraparound
  # Returns positive if seq_num > last_seq (accounting for wraparound)
  # Returns negative if seq_num < last_seq (accounting for wraparound)
  defp sequence_diff(seq_num, last_seq) do
    diff = seq_num - last_seq

    cond do
      diff > @seq_diff_threshold -> diff - (@max_seq_num + 1)
      diff < -@seq_diff_threshold -> diff + (@max_seq_num + 1)
      true -> diff
    end
  end
end
