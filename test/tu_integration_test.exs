defmodule Membrane.RTP.AV1.TUIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.AV1.{PayloadFormat, OBU}

  describe "fragment_with_markers/2 with TU detection" do
    test "single frame marks last packet" do
      frame_obu = create_frame_obu(<<0x01, 0x02, 0x03>>)

      result = PayloadFormat.fragment_with_markers(frame_obu, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      assert length(result) > 0

      # Check that only last packet has marker
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true

      # Check that all but last have no marker
      if length(result) > 1 do
        init_packets = Enum.take(result, length(result) - 1)

        Enum.each(init_packets, fn {_payload, marker} ->
          assert marker == false
        end)
      end
    end

    test "temporal delimiter + frame marks last packet" do
      td_obu = create_temporal_delimiter_obu()
      frame_obu = create_frame_obu(<<0x01, 0x02>>)
      au = td_obu <> frame_obu

      result = PayloadFormat.fragment_with_markers(au, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "large frame fragmented marks last fragment" do
      # Create large frame that requires fragmentation
      large_payload = :binary.copy(<<0x01>>, 5000)
      frame_obu = create_frame_obu(large_payload)

      result = PayloadFormat.fragment_with_markers(frame_obu, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      assert length(result) > 1

      # Verify marker bit pattern
      Enum.each(result, fn {payload, marker} ->
        assert is_binary(payload)
        assert is_boolean(marker)
      end)

      # Last packet should have marker
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "multiple small frames aggregated marks last packet" do
      frame1 = create_frame_obu(<<0x01>>)
      frame2 = create_frame_obu(<<0x02>>)
      frame3 = create_frame_obu(<<0x03>>)
      au = frame1 <> frame2 <> frame3

      result = PayloadFormat.fragment_with_markers(au, mtu: 1200, header_mode: :draft)

      assert is_list(result)

      # Should be aggregated into few packets
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "TU-aware mode can be disabled" do
      frame_obu = create_frame_obu(<<0x01, 0x02>>)

      result =
        PayloadFormat.fragment_with_markers(frame_obu,
          mtu: 1200,
          header_mode: :draft,
          tu_aware: false
        )

      assert is_list(result)
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "handles validation errors gracefully" do
      # Create malformed access unit (partial OBU)
      malformed = <<0x01, 0x02>>

      result = PayloadFormat.fragment_with_markers(malformed, mtu: 1200, header_mode: :draft)

      # Should either return packets or error
      case result do
        {:error, _reason, _context} ->
          # Error is acceptable
          assert true

        packets when is_list(packets) ->
          # If it fragments anyway, verify structure
          Enum.each(packets, fn
            {payload, marker} ->
              assert is_binary(payload)
              assert is_boolean(marker)
          end)
      end
    end

    test "sequence header + frame marks correctly" do
      seq_hdr = create_sequence_header_obu()
      frame = create_frame_obu(<<0x01, 0x02>>)
      au = seq_hdr <> frame

      result = PayloadFormat.fragment_with_markers(au, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "frame header + tile group marks correctly" do
      frame_hdr = create_frame_header_obu(<<0x01>>)
      tile_group = create_tile_group_obu(<<0x02, 0x03>>)
      au = frame_hdr <> tile_group

      result = PayloadFormat.fragment_with_markers(au, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "metadata and padding don't affect marker placement" do
      frame = create_frame_obu(<<0x01>>)
      metadata = create_metadata_obu(<<0x00>>)
      padding = create_padding_obu(<<0x00, 0x00>>)
      au = frame <> metadata <> padding

      result = PayloadFormat.fragment_with_markers(au, mtu: 1200, header_mode: :draft)

      assert is_list(result)
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "very small MTU fragments correctly with markers" do
      # Create larger frame to ensure fragmentation at MTU=64
      frame = create_frame_obu(:binary.copy(<<0x01>>, 100))

      result = PayloadFormat.fragment_with_markers(frame, mtu: 64, header_mode: :draft)

      assert is_list(result)
      # With 100 byte payload + header overhead, should definitely fragment
      assert length(result) > 1

      # Verify all packets within MTU
      Enum.each(result, fn {payload, _marker} ->
        assert byte_size(payload) <= 64
      end)

      # Last should have marker
      {_last_payload, last_marker} = List.last(result)
      assert last_marker == true
    end

    test "jumbo frames with large MTU" do
      frame = create_frame_obu(:binary.copy(<<0x01>>, 1000))

      result = PayloadFormat.fragment_with_markers(frame, mtu: 9000, header_mode: :draft)

      assert is_list(result)

      # Should fit in single packet
      assert length(result) == 1
      [{_payload, marker}] = result
      assert marker == true
    end
  end

  # Helper functions (same as TUDetectorTest)

  defp create_frame_obu(payload) do
    obu_header = <<0x32>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_temporal_delimiter_obu do
    obu_header = <<0x12>>
    OBU.build_obu(obu_header <> <<>>)
  end

  defp create_sequence_header_obu do
    obu_header = <<0x0A>>
    payload = <<0x00, 0x00, 0x00>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_frame_header_obu(payload) do
    obu_header = <<0x1A>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_tile_group_obu(payload) do
    obu_header = <<0x22>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_metadata_obu(payload) do
    obu_header = <<0x2A>>
    OBU.build_obu(obu_header <> payload)
  end

  defp create_padding_obu(payload) do
    obu_header = <<0x7A>>
    OBU.build_obu(obu_header <> payload)
  end
end
