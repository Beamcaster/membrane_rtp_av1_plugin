# Membrane RTP AV1 Plugin

Membrane RTP depayloader for AV1 following the AV1 RTP spec:
`https://aomediacodec.github.io/av1-rtp-spec/`

## Features

- OBU-aware depayloading (reassembly from aggregation and fragmentation)
- Scalability Structure (SS) support - Full decode with validation
- Temporal/Spatial layer signaling (IDS) parsing

## Usage

### Basic Setup

```elixir
def deps do
  [
    {:membrane_rtp_av1_plugin, path: "../membrane_rtp_av1_plugin"}
  ]
end
```

### Depayloader Example

```elixir
alias Membrane.RTP.AV1.Depayloader

child(:depayloader, Depayloader)
```

## Reference

- AV1 RTP spec: `https://aomediacodec.github.io/av1-rtp-spec/`
- H264 RTP plugin (reference structure): `https://github.com/membraneframework/membrane_rtp_h264_plugin`


