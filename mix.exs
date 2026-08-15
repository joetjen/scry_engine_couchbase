defmodule Scry.Engine.Couchbase.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_engine_couchbase,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Engine.Couchbase",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Shared, timing-sensitive bucket/scope provisioning (async bucket
  # creation genuinely needs polling -- `Scry.Engine.Couchbase.
  # TestSupport`'s own moduledoc has the full finding) that both real
  # test suites need identically -- unlike every prior adapter's own
  # simpler "delete every existing database" reset, factored out once
  # rather than duplicated, since it's real, nontrivial async-wait
  # logic, not a thin wrapper.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- this package implements
      # `Scry.Core.EngineBehaviour` and returns `Scry.Core.Query.t()`-
      # shaped data, so it's the real dependency, not test-only. Switch
      # to a `~> x.y` Hex requirement once scry_core is actually
      # published.
      {:scry_core, path: "../scry_core"},

      # === PARITY TESTING ===
      # `scry_document`'s own reference `Scry.Document.Executor` --
      # test-only, since AGENTS.md's "Parity between multiple
      # implementations" rule applies directly: this is the document
      # kind's *third* real adapter (after `scry_engine_mongodb_driver`/
      # `scry_engine_couchdb`), replacing the identical reference
      # executor. `scry_reldoc` itself is also test-only, needed for the
      # separate end-to-end proof this package exists to add: that the
      # relational+document composite's own correlated-nested-`SELECT`
      # semantics hold against a *third* real document backend, not
      # just asserted from `scry_engine_mongodb_driver`/
      # `scry_engine_couchdb` already having covered `scry_document`
      # itself twice over.
      {:scry_document, path: "../scry_document", only: :test},
      {:scry_reldoc, path: "../scry_reldoc", only: :test},

      # === HTTP CLIENT, NOT A DEDICATED COUCHBASE DRIVER ===
      # No official Couchbase SDK covers Elixir or Erlang at all --
      # Couchbase's own supported-SDK list stops at .NET/PHP/Ruby/
      # Python/C/Node.js/Java/Go/Scala. Every community option found
      # (`gauc`, both `cberl` forks, `couchie`) is confirmed multi-year
      # stale (2017-2023, none actively maintained), the same
      # disqualifying staleness bar `bolt_sips`/`couchdb_connector`/
      # `instream` already failed elsewhere in this family -- not an
      # architectural disqualification this time (several use an
      # acceptable runtime-`start_link`-style connection shape), simply
      # no live candidate at all. Couchbase's own Query Service exposes
      # a plain HTTP endpoint for N1QL/SQL++ (`POST :8093/query/
      # service`), the same "no client-specific protocol to speak"
      # situation `scry_engine_elasticsearch`/`scry_engine_couchdb`/
      # `scry_engine_loki`/`scry_engine_influxdb` already resolved with
      # `req` -- applied here for the identical reason.
      {:req, "~> 0.5"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "A real Scry.Core.EngineBehaviour implementation over Couchbase, replacing scry_document's " <>
      "own in-memory reference Executor with genuine bucket/scope/collection-and-N1QL-backed " <>
      "DEEP/PARENT/SIBLINGS/ANCESTORS execution -- the document kind's third real adapter, and " <>
      "scry_reldoc's own long-deferred storage adapter."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_engine_couchbase"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_engine_couchbase",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
