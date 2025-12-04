defmodule Membrane.RTP.AV1.FrameHeaderTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.FrameHeader

  doctest FrameHeader

  describe "parse_minimal/1" do
    test "parses KEY_FRAME with show_frame=1" do
      # show_existing_frame=0, frame_type=0 (KEY), show_frame=1 (implicit)
      # error_resilient_mode=1 (implicit for KEY_FRAME)
      # Add padding bits for valid bitstream
      data = <<0::1, 0::2, 0::5>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :key_frame
      assert header.show_frame == true
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == true
    end

    test "parses INTER_FRAME with show_frame=1" do
      # show_existing_frame=0, frame_type=1 (INTER), show_frame=1, error_resilient=0
      data = <<0::1, 1::2, 1::1, 0::1, 0::3>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :inter_frame
      assert header.show_frame == true
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == false
    end

    test "parses INTER_FRAME with show_frame=0" do
      # show_existing_frame=0, frame_type=1 (INTER), show_frame=0, error_resilient=1
      data = <<0::1, 1::2, 0::1, 1::1, 0::3>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :inter_frame
      assert header.show_frame == false
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == true
    end

    test "parses INTRA_ONLY_FRAME with show_frame=1" do
      # show_existing_frame=0, frame_type=2 (INTRA_ONLY), show_frame=1, error_resilient=0
      data = <<0::1, 2::2, 1::1, 0::1, 0::3>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :intra_only_frame
      assert header.show_frame == true
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == false
    end

    test "parses INTRA_ONLY_FRAME with show_frame=0" do
      # show_existing_frame=0, frame_type=2 (INTRA_ONLY), show_frame=0, error_resilient=1
      data = <<0::1, 2::2, 0::1, 1::1, 0::3>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :intra_only_frame
      assert header.show_frame == false
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == true
    end

    test "parses SWITCH_FRAME" do
      # show_existing_frame=0, frame_type=3 (SWITCH), show_frame=1 (implicit)
      # error_resilient_mode=1 (implicit for SWITCH_FRAME)
      data = <<0::1, 3::2, 0::5>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :switch_frame
      assert header.show_frame == true
      assert header.show_existing_frame == false
      assert header.error_resilient_mode == true
    end

    test "parses show_existing_frame=1" do
      # show_existing_frame=1, frame_to_show_map_idx (3 bits)
      # Treated as INTER_FRAME with show_frame=1
      data = <<1::1, 0::3, 0::4>>

      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :inter_frame
      assert header.show_frame == true
      assert header.show_existing_frame == true
      assert header.error_resilient_mode == false
    end

    test "returns error for empty binary" do
      data = <<>>
      assert {:error, :invalid_bitstream} = FrameHeader.parse_minimal(data)
    end

    test "handles minimal valid binary" do
      # Minimal KEY_FRAME: 1 byte is enough
      data = <<0::1, 0::2, 0::5>>
      assert {:ok, header} = FrameHeader.parse_minimal(data)
      assert header.frame_type == :key_frame
    end
  end

  describe "starts_temporal_unit?/1" do
    test "KEY_FRAME starts temporal unit" do
      header = %FrameHeader{frame_type: :key_frame, show_frame: true}
      assert FrameHeader.starts_temporal_unit?(header) == true
    end

    test "SWITCH_FRAME starts temporal unit" do
      header = %FrameHeader{frame_type: :switch_frame, show_frame: true}
      assert FrameHeader.starts_temporal_unit?(header) == true
    end

    test "INTRA_ONLY_FRAME with show_frame=1 starts temporal unit" do
      header = %FrameHeader{frame_type: :intra_only_frame, show_frame: true}
      assert FrameHeader.starts_temporal_unit?(header) == true
    end

    test "INTRA_ONLY_FRAME with show_frame=0 does not start temporal unit" do
      header = %FrameHeader{frame_type: :intra_only_frame, show_frame: false}
      assert FrameHeader.starts_temporal_unit?(header) == false
    end

    test "INTER_FRAME does not start temporal unit" do
      header = %FrameHeader{frame_type: :inter_frame, show_frame: true}
      assert FrameHeader.starts_temporal_unit?(header) == false
    end

    test "INTER_FRAME with show_frame=0 does not start temporal unit" do
      header = %FrameHeader{frame_type: :inter_frame, show_frame: false}
      assert FrameHeader.starts_temporal_unit?(header) == false
    end
  end

  describe "displayable?/1" do
    test "frame with show_frame=1 is displayable" do
      header = %FrameHeader{
        frame_type: :inter_frame,
        show_frame: true,
        show_existing_frame: false
      }

      assert FrameHeader.displayable?(header) == true
    end

    test "frame with show_existing_frame=1 is displayable" do
      header = %FrameHeader{
        frame_type: :inter_frame,
        show_frame: false,
        show_existing_frame: true
      }

      assert FrameHeader.displayable?(header) == true
    end

    test "frame with both show flags is displayable" do
      # This shouldn't happen in practice, but test boundary
      header = %FrameHeader{
        frame_type: :inter_frame,
        show_frame: true,
        show_existing_frame: true
      }

      assert FrameHeader.displayable?(header) == true
    end

    test "frame with show_frame=0 and show_existing_frame=0 is not displayable" do
      header = %FrameHeader{
        frame_type: :inter_frame,
        show_frame: false,
        show_existing_frame: false
      }

      assert FrameHeader.displayable?(header) == false
    end
  end

  describe "frame_type_name/1" do
    test "returns human-readable names for frame types" do
      assert FrameHeader.frame_type_name(:key_frame) == "KEY_FRAME"
      assert FrameHeader.frame_type_name(:inter_frame) == "INTER_FRAME"
      assert FrameHeader.frame_type_name(:intra_only_frame) == "INTRA_ONLY_FRAME"
      assert FrameHeader.frame_type_name(:switch_frame) == "SWITCH_FRAME"
    end
  end

  describe "integration with real-world patterns" do
    test "typical video sequence: KEY + multiple INTER frames" do
      # KEY_FRAME
      key_data = <<0::1, 0::2, 0::5>>
      assert {:ok, key_header} = FrameHeader.parse_minimal(key_data)
      assert key_header.frame_type == :key_frame
      assert FrameHeader.starts_temporal_unit?(key_header) == true

      # INTER_FRAME 1
      inter_data1 = <<0::1, 1::2, 1::1, 0::1, 0::3>>
      assert {:ok, inter_header1} = FrameHeader.parse_minimal(inter_data1)
      assert inter_header1.frame_type == :inter_frame
      assert FrameHeader.starts_temporal_unit?(inter_header1) == false

      # INTER_FRAME 2
      inter_data2 = <<0::1, 1::2, 1::1, 0::1, 0::3>>
      assert {:ok, inter_header2} = FrameHeader.parse_minimal(inter_data2)
      assert inter_header2.frame_type == :inter_frame
      assert FrameHeader.starts_temporal_unit?(inter_header2) == false
    end

    test "temporal scalability: base and enhancement layers" do
      # Base layer (INTRA_ONLY with show_frame=1) - starts TU
      base_data = <<0::1, 2::2, 1::1, 0::1, 0::3>>
      assert {:ok, base_header} = FrameHeader.parse_minimal(base_data)
      assert base_header.frame_type == :intra_only_frame
      assert base_header.show_frame == true
      assert FrameHeader.starts_temporal_unit?(base_header) == true

      # Enhancement layer (INTER with show_frame=1) - does not start TU
      enh_data = <<0::1, 1::2, 1::1, 0::1, 0::3>>
      assert {:ok, enh_header} = FrameHeader.parse_minimal(enh_data)
      assert enh_header.frame_type == :inter_frame
      assert enh_header.show_frame == true
      assert FrameHeader.starts_temporal_unit?(enh_header) == false
    end

    test "B-frames: non-displayed reference frames" do
      # INTER_FRAME with show_frame=0 (B-frame, not displayed immediately)
      b_frame_data = <<0::1, 1::2, 0::1, 0::1, 0::3>>
      assert {:ok, b_header} = FrameHeader.parse_minimal(b_frame_data)
      assert b_header.frame_type == :inter_frame
      assert b_header.show_frame == false
      assert FrameHeader.displayable?(b_header) == false
      assert FrameHeader.starts_temporal_unit?(b_header) == false
    end

    test "layer switching: SWITCH_FRAME for clean random access" do
      # SWITCH_FRAME (enables switching spatial/temporal layers)
      switch_data = <<0::1, 3::2, 0::5>>
      assert {:ok, switch_header} = FrameHeader.parse_minimal(switch_data)
      assert switch_header.frame_type == :switch_frame
      assert switch_header.show_frame == true
      assert switch_header.error_resilient_mode == true
      assert FrameHeader.starts_temporal_unit?(switch_header) == true
    end
  end
end
