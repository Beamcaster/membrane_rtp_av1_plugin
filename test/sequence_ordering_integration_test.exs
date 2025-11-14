defmodule Membrane.RTP.AV1.SequenceOrderingIntegrationTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RTP.AV1.{Depayloader, OBU}

  describe "Depayloader with sequence number validation" do
    test "accepts packets in order" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)

      packets = [
        %Buffer{
          payload: create_packet_payload(obu, :first),
          pts: 1000,
          metadata: %{rtp: %{marker: false, sequence_number: 100}}
        },
        %Buffer{
          payload: create_packet_payload(obu, :last),
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 101}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      # Should produce output
      assert length(out) > 0
    end

    test "rejects duplicate packets" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      payload = create_single_packet_payload(obu)

      packets = [
        %Buffer{
          payload: payload,
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 100}}
        },
        %Buffer{
          payload: payload,
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 100}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should only have one output (duplicate rejected)
      assert length(out_buffers) == 1
    end

    test "rejects out-of-order packets" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      obu2 = OBU.build_obu(<<0x0A, 4, 5, 6>>)

      packets = [
        %Buffer{
          payload: create_single_packet_payload(obu1),
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 100}}
        },
        %Buffer{
          payload: create_single_packet_payload(obu2),
          pts: 2000,
          metadata: %{rtp: %{marker: true, sequence_number: 99}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should only have one output (out-of-order rejected)
      assert length(out_buffers) == 1
    end

    test "handles sequence number wraparound" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      obu2 = OBU.build_obu(<<0x0A, 4, 5, 6>>)
      obu3 = OBU.build_obu(<<0x0A, 7, 8, 9>>)

      packets = [
        %Buffer{
          payload: create_single_packet_payload(obu1),
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 65534}}
        },
        %Buffer{
          payload: create_single_packet_payload(obu2),
          pts: 2000,
          metadata: %{rtp: %{marker: true, sequence_number: 65535}}
        },
        %Buffer{
          payload: create_single_packet_payload(obu3),
          pts: 3000,
          metadata: %{rtp: %{marker: true, sequence_number: 0}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should have all three outputs (wraparound handled)
      assert length(out_buffers) == 3
    end

    test "handles packets with gaps (packet loss)" do
      obu1 = OBU.build_obu(<<0x0A, 1, 2, 3>>)
      obu2 = OBU.build_obu(<<0x0A, 4, 5, 6>>)

      packets = [
        %Buffer{
          payload: create_single_packet_payload(obu1),
          pts: 1000,
          metadata: %{rtp: %{marker: true, sequence_number: 100}}
        },
        # Simulate packet loss (101, 102, 103 missing)
        %Buffer{
          payload: create_single_packet_payload(obu2),
          pts: 2000,
          metadata: %{rtp: %{marker: true, sequence_number: 104}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should accept both (gaps are allowed, indicate packet loss)
      assert length(out_buffers) == 2
    end

    test "works without sequence numbers" do
      obu = OBU.build_obu(<<0x0A, 1, 2, 3>>)

      packets = [
        %Buffer{
          payload: create_single_packet_payload(obu),
          pts: 1000,
          metadata: %{rtp: %{marker: true}}
        }
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should work fine without sequence numbers
      assert length(out_buffers) == 1
    end

    test "complex sequence with multiple issues" do
      obus =
        for i <- 1..10 do
          OBU.build_obu(<<0x0A, i>>)
        end

      # Create sequence with various issues:
      # 100, 101, 102 (dup), 105 (gap), 104 (out of order), 106
      packets = [
        create_test_packet(Enum.at(obus, 0), 100),
        create_test_packet(Enum.at(obus, 1), 101),
        create_test_packet(Enum.at(obus, 2), 102),
        create_test_packet(Enum.at(obus, 2), 102),
        # duplicate
        create_test_packet(Enum.at(obus, 3), 105),
        # gap
        create_test_packet(Enum.at(obus, 4), 104),
        # out of order
        create_test_packet(Enum.at(obus, 5), 106)
      ]

      {_actions, state} = Depayloader.handle_init(nil, %{clock_rate: 90_000})
      {_sf_actions, state} = Depayloader.handle_stream_format(:input, :any, nil, state)

      {out, _state} =
        Enum.reduce(packets, {[], state}, fn buffer, {acc, st} ->
          {acts, st2} = Depayloader.handle_buffer(:input, buffer, nil, st)
          {acc ++ acts, st2}
        end)

      out_buffers =
        out
        |> Enum.flat_map(fn
          {:buffer, {_pad_ref, buffer}} -> [buffer]
          _ -> []
        end)

      # Should have: 100, 101, 102, 105 (gap accepted), 106
      # Rejected: duplicate 102, out-of-order 104
      assert length(out_buffers) == 5
    end
  end

  # Helper functions

  defp create_test_packet(obu, seq_num) do
    %Buffer{
      payload: create_single_packet_payload(obu),
      pts: seq_num * 1000,
      metadata: %{rtp: %{marker: true, sequence_number: seq_num}}
    }
  end

  defp create_single_packet_payload(obu) do
    # Create a simple draft header: S=1, E=1, F=0, C=0
    header = <<1::1, 1::1, 0::1, 0::5>>
    header <> obu
  end

  defp create_packet_payload(obu, :first) do
    # S=1, E=0, F=1, C=0
    header = <<1::1, 0::1, 1::1, 0::5>>
    # Split OBU in half for testing
    half = div(byte_size(obu), 2)
    <<chunk::binary-size(half), _::binary>> = obu
    header <> chunk
  end

  defp create_packet_payload(_obu, :last) do
    # S=0, E=1, F=1, C=0
    header = <<0::1, 1::1, 1::1, 0::5>>
    # Return second half (dummy data for test)
    header <> <<4, 5, 6>>
  end
end
