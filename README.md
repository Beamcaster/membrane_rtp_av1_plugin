# Membrane RTP AV1 Plugin

Membrane RTP payloader/depayloader for AV1 following the AV1 RTP spec:
`https://aomediacodec.github.io/av1-rtp-spec/`

## Features

- ✅ OBU-aware packetization (aggregation and fragmentation)
- ✅ Multiple header modes (draft, spec with full AV1 RTP descriptor)
- ✅ **Scalability Structure (SS) support** - Full encode/decode with validation
- ✅ Temporal/Spatial layer signaling (IDS)
- ✅ Configurable MTU
- ✅ Round-trip tested (payloader ↔ depayloader)

## Recent Updates

### Scalability Structure Implementation (v0.1.0)

Fully implemented **Scalability Structure (SS)** per AV1 RTP spec:
- Complete SS encode/decode with comprehensive validation
- Size limits enforced (max 255 bytes per spec)
- Helper constructors: `ScalabilityStructure.simple/2` and `ScalabilityStructure.svc/2`
- Integration with `FullHeader` (Z=1 flag)
- FMTP support for SS in SDP (hex-encoded `ss_data`)
- 33 tests covering all SS scenarios

## Usage

### Basic Setup

```elixir
def deps do
  [
    {:membrane_rtp_av1_plugin, path: "../membrane_rtp_av1_plugin"}
  ]
end
```

### Payloader Example

```elixir
alias Membrane.RTP.AV1.{Payloader, ScalabilityStructure}

# Create scalability structure for 1080p with 2 temporal layers
ss = ScalabilityStructure.simple(1920, 1080,
  frame_rate: 30,
  temporal_layers: 2
)

# Configure payloader
payloader_opts = [
  mtu: 1200,
  payload_type: 96,
  clock_rate: 90_000,
  header_mode: :spec,  # Use full AV1 RTP spec headers
  fmtp: %{
    cm: 1,              # Congestion management
    tid: 0,             # Base temporal layer
    ss: ss              # Include SS in first packet
  }
]

# In your pipeline:
child(:payloader, %Payloader{payloader_opts})
```

### Depayloader Example

```elixir
alias Membrane.RTP.AV1.Depayloader

depayloader_opts = [
  clock_rate: 90_000,
  header_mode: :spec,
  fmtp: %{}
]

child(:depayloader, %Depayloader{depayloader_opts})
```

### SVC (Scalable Video Coding) Example

```elixir
# Create multi-layer SVC structure
spatial_layers = [
  {640, 360},   # Layer 0
  {1280, 720},  # Layer 1
  {1920, 1080}  # Layer 2
]

ss = ScalabilityStructure.svc(spatial_layers, 3)  # 3 temporal layers

# Use in payloader fmtp
fmtp = %{
  cm: 1,
  ss: ss,
  tid: 0,  # Start at base temporal layer
  lid: 0   # Start at base spatial layer
}
```

## Reference

- AV1 RTP draft: `https://aomediacodec.github.io/av1-rtp-spec/`
- H264 RTP plugin (reference structure): `https://github.com/membraneframework/membrane_rtp_h264_plugin`


