defmodule Membrane.RTP.AV1.Examples.ScalabilityStructure do
  @moduledoc """
  Examples demonstrating how to use the Scalability Structure (SS) implementation.
  """

  alias Membrane.RTP.AV1.{ScalabilityStructure, FullHeader, FMTP}

  @doc """
  Example 1: Create a simple single-layer 1080p stream structure.
  """
  def example_simple_structure do
    # Create SS for 1080p stream with 3 temporal layers
    ss =
      ScalabilityStructure.simple(1920, 1080,
        frame_rate: 30,
        temporal_layers: 3
      )

    IO.puts("Simple Structure:")
    IO.inspect(ss, pretty: true)

    # Encode to binary
    {:ok, binary} = ScalabilityStructure.encode(ss)
    IO.puts("\nEncoded size: #{byte_size(binary)} bytes")
    IO.puts("Hex: #{Base.encode16(binary)}")

    # Decode back
    {:ok, decoded, _rest} = ScalabilityStructure.decode(binary)
    IO.puts("\nDecoded matches original: #{ss == decoded}")

    ss
  end

  @doc """
  Example 2: Create a multi-layer SVC structure for adaptive streaming.
  """
  def example_svc_structure do
    # Define 3 spatial resolutions (360p, 720p, 1080p)
    spatial_layers = [
      # Layer 0: Low resolution
      {640, 360},
      # Layer 1: Medium resolution
      {1280, 720},
      # Layer 2: High resolution
      {1920, 1080}
    ]

    # Create SS with 2 temporal layers per spatial layer
    ss = ScalabilityStructure.svc(spatial_layers, 2)

    IO.puts("SVC Structure:")
    IO.puts("Spatial layers: #{ss.n_s + 1}")
    IO.puts("Pictures: #{ss.n_g}")
    IO.inspect(ss.spatial_layers, pretty: true)

    {:ok, binary} = ScalabilityStructure.encode(ss)
    IO.puts("\nEncoded SVC size: #{byte_size(binary)} bytes")

    ss
  end

  @doc """
  Example 3: Include SS in RTP header (Z=1 flag).
  """
  def example_ss_in_rtp_header do
    # Create a simple SS
    ss = ScalabilityStructure.simple(1280, 720, temporal_layers: 2)

    # Create RTP header with SS present (Z=1)
    header = %FullHeader{
      # SS present
      z: true,
      # First OBU in TU
      y: true,
      # Not fragmented
      w: 0,
      # Not non-reference
      n: false,
      # No aggregation count
      c: 0,
      # IDS present
      m: true,
      # Temporal layer 1
      temporal_id: 1,
      # Base spatial layer
      spatial_id: 0,
      scalability_structure: ss
    }

    # Encode header with SS
    encoded_header = FullHeader.encode(header)
    IO.puts("Header with SS:")
    IO.puts("Size: #{byte_size(encoded_header)} bytes")
    IO.puts("Hex: #{Base.encode16(encoded_header)}")

    # Decode and verify
    {:ok, decoded_header, _rest} = FullHeader.decode(encoded_header)
    IO.puts("\nDecoded header:")
    IO.puts("Z (SS present): #{decoded_header.z}")
    IO.puts("M (IDS present): #{decoded_header.m}")
    IO.puts("Temporal ID: #{decoded_header.temporal_id}")
    IO.puts("Spatial ID: #{decoded_header.spatial_id}")
    IO.puts("SS layers: #{decoded_header.scalability_structure.n_s + 1}")

    encoded_header
  end

  @doc """
  Example 4: Parse SS from SDP fmtp parameters.
  """
  def example_ss_from_sdp do
    # Create and encode SS
    ss = ScalabilityStructure.simple(1920, 1080, frame_rate: 60)
    {:ok, ss_binary} = ScalabilityStructure.encode(ss)

    # Convert to hex (as it would appear in SDP)
    ss_hex = Base.encode16(ss_binary)

    # Simulate SDP fmtp line: "a=fmtp:96 cm=1;tid=0;ss_data=<hex>"
    fmtp_params = %{
      "cm" => "1",
      "tid" => "0",
      "ss_data" => ss_hex
    }

    # Parse fmtp
    parsed = FMTP.parse(fmtp_params)

    IO.puts("SDP FMTP Example:")
    IO.puts("ss_data (hex): #{ss_hex}")
    IO.puts("\nParsed FMTP:")
    IO.puts("CM: #{parsed.cm}")
    IO.puts("Temporal ID: #{parsed.temporal_id}")
    IO.puts("SS present: #{not is_nil(parsed.scalability_structure)}")

    if parsed.scalability_structure do
      IO.puts(
        "SS resolution: #{hd(parsed.scalability_structure.spatial_layers).width}x#{hd(parsed.scalability_structure.spatial_layers).height}"
      )
    end

    parsed
  end

  @doc """
  Example 5: Custom SS with specific dependency structure.
  """
  def example_custom_structure do
    # Manual SS construction for fine-grained control
    ss = %ScalabilityStructure{
      # 2 spatial layers
      n_s: 1,
      # Frame rate included
      y_flag: false,
      # 4 pictures in dependency group
      n_g: 4,
      spatial_layers: [
        %{width: 640, height: 360, frame_rate: 30},
        %{width: 1280, height: 720, frame_rate: 30}
      ],
      pictures: [
        # Keyframe at base layer
        %{temporal_id: 0, spatial_id: 0, reference_count: 0, p_diffs: [0, 0]},

        # Keyframe at high layer (depends on base keyframe)
        %{temporal_id: 0, spatial_id: 1, reference_count: 1, p_diffs: [1, 0]},

        # P-frame at base layer
        %{temporal_id: 1, spatial_id: 0, reference_count: 1, p_diffs: [2, 0]},

        # P-frame at high layer (depends on high keyframe and base P-frame)
        %{temporal_id: 1, spatial_id: 1, reference_count: 2, p_diffs: [2, 2]}
      ]
    }

    IO.puts("Custom SS with dependencies:")
    IO.inspect(ss, pretty: true)

    # Validate
    case ScalabilityStructure.encode(ss) do
      {:ok, binary} ->
        IO.puts("\n✓ Valid structure, encoded to #{byte_size(binary)} bytes")

      {:error, reason} ->
        IO.puts("\n✗ Invalid structure: #{reason}")
    end

    ss
  end

  @doc """
  Run all examples.
  """
  def run_all do
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("AV1 RTP Scalability Structure Examples")
    IO.puts("=" <> String.duplicate("=", 70) <> "\n")

    IO.puts("\n--- Example 1: Simple Structure ---")
    example_simple_structure()

    IO.puts("\n\n--- Example 2: SVC Structure ---")
    example_svc_structure()

    IO.puts("\n\n--- Example 3: SS in RTP Header ---")
    example_ss_in_rtp_header()

    IO.puts("\n\n--- Example 4: SS from SDP ---")
    example_ss_from_sdp()

    IO.puts("\n\n--- Example 5: Custom Structure ---")
    example_custom_structure()

    IO.puts("\n" <> String.duplicate("=", 72))
    :ok
  end
end
