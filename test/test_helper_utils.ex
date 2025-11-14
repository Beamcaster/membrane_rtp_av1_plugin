defmodule Membrane.RTP.AV1.TestHelperUtils do
  @moduledoc """
  Utility functions for tests to handle both static and dynamic pad references.
  """

  alias Membrane.Pad
  require Membrane.Pad

  @doc """
  Extracts buffers from actions, handling both old-style static pad references
  (`:output`) and new-style dynamic pad references (`{Membrane.Pad, :output, id}`).
  """
  def extract_output_buffers(actions) do
    actions
    |> Enum.flat_map(fn
      # Old style: {:buffer, {:output, buffer}}
      {:buffer, {:output, buffer}} -> [buffer]
      # New style: {:buffer, {{Membrane.Pad, :output, _id}, buffer}}
      {:buffer, {{Membrane.Pad, :output, _id}, buffer}} -> [buffer]
      _ -> []
    end)
  end

  @doc """
  Checks if actions contain a buffer output action (any output pad).
  """
  def has_buffer_output?(actions) do
    Enum.any?(actions, fn
      {:buffer, {:output, _}} -> true
      {:buffer, {{Membrane.Pad, :output, _}, _}} -> true
      _ -> false
    end)
  end

  @doc """
  Extracts the first buffer from actions, or nil if none found.
  """
  def first_output_buffer(actions) do
    actions
    |> extract_output_buffers()
    |> List.first()
  end

  @doc """
  Normalizes buffer actions to handle both patterns.
  Returns a list of {pad_ref, buffer} tuples.
  """
  def normalize_buffer_actions(actions) do
    actions
    |> Enum.flat_map(fn
      {:buffer, {:output, buffer}} -> [{Pad.ref(:output, 0), buffer}]
      {:buffer, {pad_ref, buffer}} when is_tuple(pad_ref) -> [{pad_ref, buffer}]
      _ -> []
    end)
  end

  @doc """
  Extracts actions and state from handle_buffer result, filtering out notify_parent actions.
  Returns {actions, state} where actions only includes non-notify_parent actions.
  Useful for tests that need to pattern match on buffer actions without notify_parent noise.
  """
  def extract_actions_and_state({actions, state}) do
    filtered_actions =
      actions
      |> Enum.reject(fn
        {:notify_parent, _} -> true
        _ -> false
      end)

    {filtered_actions, state}
  end
end
