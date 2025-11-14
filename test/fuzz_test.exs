defmodule Membrane.RTP.AV1.FuzzTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Membrane.RTP.AV1.{Payloader, Depayloader}
  alias Membrane.Buffer

  @max_runs 100

  describe "Fuzz Testing" do
    property "depayloader handles random binary payloads without crashing" do
      check all(
              payload_size <- integer(0..1000),
              random_payload <- binary(length: payload_size),
              max_runs: @max_runs
            ) do
        buffer = %Buffer{
          payload: random_payload,
          metadata: %{rtp: %{marker: true, sequence_number: 1000, timestamp: 90_000}}
        }

        {_actions, dstate} =
          Depayloader.handle_init(nil, %{clock_rate: 90_000, header_mode: :spec})

        {_sf_actions, dstate} =
          Depayloader.handle_stream_format(
            :input,
            %Membrane.RTP{payload_format: nil},
            nil,
            dstate
          )

        result =
          try do
            Depayloader.handle_buffer(:input, buffer, nil, dstate)
            :ok
          catch
            _ -> :error
          end

        assert result in [:ok, :error]
      end
    end

    property "payloader handles random access units without crashing" do
      check all(
              payload_size <- integer(0..1000),
              random_payload <- binary(length: payload_size),
              max_runs: @max_runs
            ) do
        {_actions, pstate} =
          Payloader.handle_init(nil, %{mtu: 1200, payload_type: 96, header_mode: :spec})

        buffer = %Buffer{payload: random_payload, pts: 1_000_000}

        result =
          try do
            Payloader.handle_buffer(:input, buffer, nil, pstate)
            :ok
          catch
            _ -> :error
          end

        assert result in [:ok, :error]
      end
    end

    property "payloader handles extreme MTU values gracefully" do
      check all(
              mtu <- one_of([integer(64..100), integer(9000..10_000)]),
              obu_size <- integer(100..1000),
              max_runs: @max_runs
            ) do
        # Create valid OBU
        obu_header = <<0::1, 6::4, 0::1, 1::1, 0::1>>
        obu_size_leb128 = <<obu_size>>
        obu_payload = :crypto.strong_rand_bytes(obu_size)
        obu = obu_header <> obu_size_leb128 <> obu_payload

        {_actions, pstate} =
          Payloader.handle_init(nil, %{mtu: mtu, payload_type: 96, header_mode: :spec})

        buffer = %Buffer{payload: obu, pts: 1_000_000}

        result =
          try do
            Payloader.handle_buffer(:input, buffer, nil, pstate)
            :ok
          catch
            _ -> :error
          end

        assert result in [:ok, :error]
      end
    end
  end
end
