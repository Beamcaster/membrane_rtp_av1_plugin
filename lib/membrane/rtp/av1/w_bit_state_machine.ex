defmodule Membrane.RTP.AV1.WBitStateMachine do
  @moduledoc """
  W-bit state machine for AV1 RTP fragmentation validation.

  The W-bit indicates fragmentation state:
  - W=0: Single complete OBU(s), not fragmented
  - W=1: First fragment of OBU
  - W=2: Middle fragment of OBU
  - W=3: Last fragment of OBU

  Valid state transitions:
  - Standalone: W=0 (can repeat)
  - Fragment sequence: W=1 → W=2* → W=3 (then reset)
  - Invalid: W=0→2, W=0→3, W=1→0, W=1→3, W=2→0, W=2→1, W=3→2, etc.

  The state machine enforces:
  1. Fragments must start with W=1
  2. Middle fragments (W=2) can only follow W=1 or W=2
  3. Last fragment (W=3) can only follow W=1 or W=2
  4. After W=3 (or W=0), next packet must be W=0 or W=1
  5. No mixing of W=0 with fragment sequences
  """

  @type w_value :: 0..3
  @type state :: :idle | :in_fragment
  @type t :: %__MODULE__{
          state: state(),
          last_w: w_value() | nil
        }

  defstruct state: :idle,
            last_w: nil

  @doc """
  Creates a new W-bit state machine in idle state.

  ## Examples

      iex> WBitStateMachine.new()
      %WBitStateMachine{state: :idle, last_w: nil}
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Validates and transitions the state machine based on the next W value.

  Returns {:ok, new_state} if the transition is valid, or {:error, reason} if invalid.

  ## Examples

      # Standalone packets (W=0)
      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 0)
      iex> {:ok, sm} = WBitStateMachine.next(sm, 0)
      iex> sm.state
      :idle

      # Valid fragment sequence: W=1 → W=2 → W=3
      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 1)
      iex> {:ok, sm} = WBitStateMachine.next(sm, 2)
      iex> {:ok, sm} = WBitStateMachine.next(sm, 3)
      iex> sm.state
      :idle

      # Invalid transition: W=0 → W=2
      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 0)
      iex> WBitStateMachine.next(sm, 2)
      {:error, :invalid_w_transition}

      # Invalid transition: W=1 → W=0
      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 1)
      iex> WBitStateMachine.next(sm, 0)
      {:error, :invalid_w_transition}
  """
  @spec next(t(), w_value()) :: {:ok, t()} | {:error, atom()}
  def next(%__MODULE__{state: state, last_w: last_w} = sm, w) when w in 0..3 do
    case validate_transition(state, last_w, w) do
      :ok ->
        new_state = next_state(state, w)
        {:ok, %{sm | state: new_state, last_w: w}}

      {:error, _reason} = error ->
        error
    end
  end

  def next(_sm, _w) do
    {:error, :invalid_w_value}
  end

  @doc """
  Resets the state machine to idle state.

  Useful for error recovery or stream discontinuities.

  ## Examples

      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 1)
      iex> sm = WBitStateMachine.reset(sm)
      iex> sm.state
      :idle
  """
  @spec reset(t()) :: t()
  def reset(_sm) do
    new()
  end

  @doc """
  Checks if the state machine is currently expecting more fragments.

  Returns true if in the middle of a fragment sequence (W=1 or W=2 seen but not W=3).

  ## Examples

      iex> sm = WBitStateMachine.new()
      iex> WBitStateMachine.incomplete_fragment?(sm)
      false

      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 1)
      iex> WBitStateMachine.incomplete_fragment?(sm)
      true

      iex> sm = WBitStateMachine.new()
      iex> {:ok, sm} = WBitStateMachine.next(sm, 1)
      iex> {:ok, sm} = WBitStateMachine.next(sm, 3)
      iex> WBitStateMachine.incomplete_fragment?(sm)
      false
  """
  @spec incomplete_fragment?(t()) :: boolean()
  def incomplete_fragment?(%__MODULE__{state: :in_fragment}), do: true
  def incomplete_fragment?(%__MODULE__{state: :idle}), do: false

  @doc """
  Returns a human-readable error message for W-bit transition errors.

  ## Examples

      iex> WBitStateMachine.error_message({:error, :invalid_w_transition})
      "Invalid W-bit transition: fragments must follow sequence W=1→W=2*→W=3"

      iex> WBitStateMachine.error_message({:error, :fragment_not_started})
      "Fragment not started: W=2 or W=3 requires prior W=1"

      iex> WBitStateMachine.error_message({:error, :incomplete_fragment})
      "Incomplete fragment: W=0 cannot follow W=1 or W=2 without W=3"
  """
  @spec error_message({:error, atom()}) :: String.t()
  def error_message({:error, :invalid_w_transition}) do
    "Invalid W-bit transition: fragments must follow sequence W=1→W=2*→W=3"
  end

  def error_message({:error, :fragment_not_started}) do
    "Fragment not started: W=2 or W=3 requires prior W=1"
  end

  def error_message({:error, :incomplete_fragment}) do
    "Incomplete fragment: W=0 cannot follow W=1 or W=2 without W=3"
  end

  def error_message({:error, :invalid_w_value}) do
    "W value must be 0, 1, 2, or 3"
  end

  def error_message(_) do
    "Unknown W-bit state machine error"
  end

  # Private helpers

  # Validate state transition based on current state and W values
  defp validate_transition(:idle, nil, w) when w in [0, 1] do
    # Initial state: can start with W=0 (standalone) or W=1 (first fragment)
    :ok
  end

  defp validate_transition(:idle, nil, _w) do
    # Initial state: cannot start with W=2 or W=3
    {:error, :fragment_not_started}
  end

  defp validate_transition(:idle, 0, w) when w in [0, 1] do
    # After standalone (W=0): can continue with W=0 or start fragment with W=1
    :ok
  end

  defp validate_transition(:idle, 0, _w) do
    # After standalone (W=0): cannot jump to W=2 or W=3
    {:error, :fragment_not_started}
  end

  defp validate_transition(:idle, 3, w) when w in [0, 1] do
    # After last fragment (W=3): can go to standalone (W=0) or new fragment (W=1)
    :ok
  end

  defp validate_transition(:idle, 3, _w) do
    # After last fragment (W=3): cannot go to W=2 or W=3 directly
    {:error, :invalid_w_transition}
  end

  defp validate_transition(:in_fragment, 1, w) when w in [2, 3] do
    # After first fragment (W=1): can go to middle (W=2) or last (W=3)
    :ok
  end

  defp validate_transition(:in_fragment, 1, _w) do
    # After first fragment (W=1): cannot go back to W=0 or W=1
    {:error, :incomplete_fragment}
  end

  defp validate_transition(:in_fragment, 2, w) when w in [2, 3] do
    # After middle fragment (W=2): can continue with W=2 or end with W=3
    :ok
  end

  defp validate_transition(:in_fragment, 2, _w) do
    # After middle fragment (W=2): cannot go back to W=0 or W=1
    {:error, :incomplete_fragment}
  end

  defp validate_transition(_state, _last_w, _w) do
    {:error, :invalid_w_transition}
  end

  # Determine next state based on current state and W value
  defp next_state(:idle, 1), do: :in_fragment
  defp next_state(:idle, _w), do: :idle
  defp next_state(:in_fragment, 3), do: :idle
  defp next_state(:in_fragment, _w), do: :in_fragment
end
