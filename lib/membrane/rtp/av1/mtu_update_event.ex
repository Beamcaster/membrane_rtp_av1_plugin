defmodule Membrane.RTP.AV1.MTUUpdateEvent do
  @moduledoc """
  Event for dynamically updating the MTU (Maximum Transmission Unit) of the AV1 RTP payloader.

  This event allows changing the maximum RTP payload size at runtime, which is useful for:
  - Adapting to network conditions
  - Responding to RTCP feedback about packet loss
  - Path MTU discovery results
  - Manual tuning based on application requirements

  ## MTU Constraints

  - Minimum: 64 bytes (to accommodate RTP headers)
  - Maximum: 9000 bytes (jumbo frames)
  - Default: 1200 bytes (safe for most networks)
  - Recommended: 1200-1500 bytes for Internet traffic

  Values outside the valid range will be clamped to the nearest boundary.

  ## Usage

  ```elixir
  # Send event to payloader to change MTU
  event = %Membrane.RTP.AV1.MTUUpdateEvent{mtu: 1500}
  {[event: {:payloader, event}], state}
  ```

  ## RTCP Integration

  This event can be triggered based on RTCP feedback:
  - High packet loss → reduce MTU
  - Stable transmission → try larger MTU (up to 9000 for local networks)
  - Path MTU discovery results → adjust accordingly
  """

  @derive Membrane.EventProtocol
  @enforce_keys [:mtu]
  defstruct @enforce_keys

  @typedoc """
  MTU update event structure.

  - `:mtu` - New MTU value in bytes (will be clamped to 64-9000 range)
  """
  @type t :: %__MODULE__{
          mtu: pos_integer()
        }
end
