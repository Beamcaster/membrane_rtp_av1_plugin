defmodule Membrane.RTP.AV1.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_rtp_av1_plugin,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Membrane RTP AV1 plugin (payloader/depayloader) per AV1 RTP draft",
      package: package(),
      source_url: "https://github.com/membraneframework/membrane_rtp_av1_plugin"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_plugin, "~> 0.24"},
      {:membrane_raw_video_format, "~> 0.4.1"},
      {:bunch, "~> 1.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: :test},
      {:rav1d_ex, ">= 0.0.0", organization: "beamcaster"}
    ]
  end

  defp package do
    [
      organization: "beamcaster",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/membraneframework/membrane_rtp_av1_plugin",
        "AV1 RTP Spec (draft)" => "https://aomediacodec.github.io/av1-rtp-spec/"
      }
    ]
  end
end
