defmodule Photon.MixProject do
  use Mix.Project

  def project do
    [
      app: :photon,
      version: "1.0.0",
      elixir: "~> 1.14.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :ssl, :inets],
    ]
  end

  defp deps do
    [
      {:exjsx, "~> 4.0.0"},
      
      #for cert pin
      {:certifi, "~> 2.0"},
      {:ssl_verify_fun, "~> 1.1", [env: :prod, hex: "ssl_verify_fun", repo: "hexpm", optional: false]},
      {:parse_trans, git: "https://github.com/uwiger/parse_trans"},
    ]
  end
end
