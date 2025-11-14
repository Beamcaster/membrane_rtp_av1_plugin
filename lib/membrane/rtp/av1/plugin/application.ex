defmodule Membrane.RTP.AV1.Plugin.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Register AV1 payload format with Membrane.RTP
    Membrane.RTP.AV1.__register__()

    # No supervisor needed - registration is done
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
