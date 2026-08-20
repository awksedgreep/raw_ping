defmodule RawPing.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/awksedgreep/raw_ping"

  def project do
    [
      app: :raw_ping,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RawPing.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Pure Erlang/OTP ICMP ping library using the modern :socket API.
    No NIFs, no external dependencies. Requires Elixir 1.17+ (OTP 25+).
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["awksedgreep"],
      files: ~w(lib .formatter.exs .iex.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "RawPing",
      source_ref: "v#{@version}"
    ]
  end
end
