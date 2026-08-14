defmodule Scry.Engine.Couchbase do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over Couchbase, via
  [`req`](https://hex.pm/packages/req) -- not a dedicated Couchbase
  client. Replaces `scry_document`'s own in-memory reference
  implementation (`Scry.Document.Executor`) with genuine
  bucket/scope/collection-and-N1QL-backed `DEEP`/`PARENT`/`SIBLINGS`/
  `ANCESTORS` execution against a *third* real document store, after
  [`scry_engine_mongodb_driver`](https://github.com/joetjen/scry_engine_mongodb_driver)
  and
  [`scry_engine_couchdb`](https://github.com/joetjen/scry_engine_couchdb)
  -- and, not incidentally, `scry_reldoc`'s own long-deferred storage
  adapter (impl_spec.md §6 had named Couchbase there from the start,
  deferred as lower marginal value than `scry_docgraph`'s own ArangoDB
  landing, since `scry_reldoc` is a thin delegate to `scry_document`
  already validated twice over -- confirming the correlated-nested-
  `SELECT` composition holds against a genuinely different backend is
  this package's own real, distinct contribution, not a rerun of
  already-settled ground).

  ## No dedicated driver -- confirmed, not assumed

  No official Couchbase SDK covers Elixir or Erlang at all (Couchbase's
  own supported list stops at .NET/PHP/Ruby/Python/C/Node.js/Java/Go/
  Scala). Every community option found (`gauc`, two independent
  `cberl` forks, `couchie`) is confirmed multi-year stale (last
  release/commit 2017-2023, none actively maintained) -- the same
  disqualifying bar `bolt_sips`/`couchdb_connector`/`instream` already
  failed elsewhere in this family, just with no live alternative to
  fall back to at all this time. Couchbase's own Query Service exposes
  a plain HTTP endpoint for N1QL/SQL++ (`POST :8093/query/service`) --
  the identical "no client-specific protocol to speak" situation
  `scry_engine_elasticsearch`/`scry_engine_couchdb`/`scry_engine_loki`/
  `scry_engine_influxdb` already resolved with `req`, applied here for
  the same reason (`Scry.Engine.Couchbase.Conn`'s own moduledoc has the
  full driver-landscape finding).

  ## Bucket + scope, fixed at `Conn.open/1` time; collection-per-tree-key, joined with `__`

  Couchbase's own data model nests one level deeper than either prior
  document adapter in this family: bucket > scope > collection >
  document, not MongoDB's flat database > collection or CouchDB's
  server > database. `bucket`/`scope` together play the identical
  fixed-context role `Scry.Engine.MongoDB.Conn`'s own `database` plays
  -- set once at `Conn.open/1` time, never derived from a query's own
  source path -- and one real Couchbase *collection* per tree-position
  key, segments joined with `__` (not `.`: Couchbase's own collection-
  naming rule disallows a literal `.` outright, confirmed directly,
  the identical restriction `scry_engine_couchdb`/`scry_engine_
  arangodb` already found for their own database/collection names),
  lives inside that fixed bucket/scope -- the exact granularity
  `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` all operate at.

  ## A real, load-bearing consistency finding

  Couchbase's own default N1QL scan consistency (`not_bounded`) is
  genuinely eventually-consistent against its own global secondary
  indexer -- confirmed directly, a document inserted immediately before
  an unqualified `SELECT` came back with zero rows, a real correctness
  risk no adapter in this family can silently accept. `Scry.Engine.
  Couchbase.Conn.n1ql/3` always forces `scan_consistency: "request_plus"`,
  blocking until the index has caught up to the request's own start
  time -- unlike every prior adapter's own consistency story, this
  isn't a translation-surface finding but a "the backend has a real
  staleness knob and this package always turns it to the strict
  setting" one.

  A second, confirmed-for-this-version-specifically finding: unlike
  older Couchbase releases (which require an explicit `CREATE PRIMARY
  INDEX` before any unfiltered scan), Couchbase Server 7.6's own
  index-free full-collection-scan capability means this package issues
  no index-management calls at all -- confirmed directly against a
  real `couchbase:community-7.6.2` container, a freshly-created,
  never-indexed collection answers `SELECT d.* FROM ...` correctly the
  moment a document exists in it.

  ## No pushdown at all -- everything but hierarchy resolution is generic

  The identical posture `scry_engine_mongodb_driver`/`scry_engine_
  couchdb` already establish, for the identical reason: every one of
  `WHERE`/`GROUP BY`/aggregates/`HAVING`/`DISTINCT`/`ORDER BY`/`LIMIT`/
  `OFFSET`/projection applies generically via `Scry.Core.QueryOps.
  run_flat/3`, never translated into N1QL. N1QL is a real, expressive
  SQL++ dialect this package deliberately doesn't reach for beyond a
  bare `SELECT d.* FROM <collection> AS d` -- the only real adapter-
  specific work, mirroring the reference `Executor`'s own architecture
  exactly, is knowing *which collection(s)* to read.

  ## A missing collection is an error, matching the reference

  The identical divergence-from-MongoDB `scry_engine_couchdb` already
  states, confirmed again here on independent grounds: a Couchbase
  collection must be explicitly created (via the Cluster Manager REST
  API) before anything can be read from it -- confirmed directly, a
  `SELECT` against a collection that was never created returns N1QL
  error `12003` ("Keyspace not found"), not an empty result. So for an
  ordinary (non-`DEEP`) `resolve_source/3`, this package matches the
  reference's own strict `{:error, {:query_error, {:no_such_source,
  _}}}` behavior, the same "a real backend forcing more alignment with
  the reference, not a scope choice" story `scry_engine_couchdb`
  already tells.

  `PARENT`/`SIBLINGS`/`ANCESTORS`/`DEEP` combined with `GROUP BY`, and
  `%Scry.Core.CombinedQuery{}`, decline exactly like the reference
  (`{:unsupported, :pseudo_field_with_group_by}`/`{:unsupported,
  :combined_query}`, atom names kept byte-for-byte identical, the same
  convention every real document/graph adapter in this family already
  keeps). A `WITH`-bound top-level `source` delegates to `Scry.Core.
  QueryOps.run_document/4` rather than declining outright, the same
  upgrade every real adapter past `scry_engine_neo4j` already makes
  over its own reference.

  Unlike `_id`/`_rev` in `Scry.Engine.CouchDB.Conn`/`_id` in `Scry.
  Engine.MongoDB.Conn` (both always present, always stripped), no
  document-identity field ever needs stripping here at all: this
  package only ever projects `d.*` in its own N1QL `SELECT`, never
  `META(d).id`, so nothing but a document's own real fields is ever
  returned in the first place -- a real, adapter-specific simplification
  this backend's own query-shaping control makes possible, not a
  deliberate scope choice the way it was for its siblings.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}
  alias Scry.Engine.Couchbase.Conn

  @document_key_field "__scry_couchbase_key__"
  @separator "__"

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{} = query, params) do
    if with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      run(conn, query, params)
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run(conn, query, params) do
    with {:ok, matches} <- resolve_source(conn, query.source, deep?(query)) do
      if special_items?(query.select) do
        run_with_special_items(conn, query, matches, params)
      else
        run_flat_over_matches(matches, query, params)
      end
    end
  end

  # Neither a PARENT/SIBLINGS/ANCESTORS pseudo-field nor a nested SELECT
  # anywhere in this query's own top-level select -- nothing document-
  # specific to do. Delegating wholesale, unmodified query included, is
  # the correctness-critical path here (GROUP BY/aggregation only works
  # correctly when run_flat/3 sees every row belonging to a group at
  # once), the identical reasoning every prior document/graph adapter
  # in this family already states.
  defp run_flat_over_matches(matches, query, params) do
    rows = Enum.map(matches, fn {_key, row} -> row end)
    QueryOps.run_flat(rows, query, params)
  end

  defp run_with_special_items(conn, query, matches, params) do
    with :ok <- validate_no_grouping(query),
         {:ok, ordered} <- order_and_limit(matches, query, params) do
      own_name = List.last(query.source)
      project_all(ordered, query.select, conn, own_name, params)
    end
  end

  defp special_items?(body_items) do
    Enum.any?(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      %Query{} -> true
      _other -> false
    end)
  end

  defp deep?(%Query{variant: %{select_ep1a: :deep}}), do: true
  defp deep?(_query), do: false

  defp validate_no_grouping(%Query{group_bys: []}), do: :ok
  defp validate_no_grouping(_query), do: {:error, {:unsupported, :pseudo_field_with_group_by}}

  defp resolve_source(conn, source, false) do
    case Conn.all_docs(conn, collection_name(source)) do
      {:ok, rows} -> {:ok, Enum.map(rows, &{source, &1})}
      {:error, :not_found} -> {:error, {:query_error, {:no_such_source, source}}}
      {:error, {:query_error, _}} = error -> error
    end
  end

  defp resolve_source(conn, source, true) do
    with {:ok, names} <- Conn.collection_names(conn) do
      keys =
        names
        |> Enum.map(&String.split(&1, @separator))
        |> Enum.filter(&deep_match?(&1, source))
        |> Enum.sort()

      fetch_all(conn, keys)
    end
  end

  defp deep_match?(key, [only]), do: List.last(key) == only

  defp deep_match?(key, source),
    do: List.first(key) == List.first(source) and List.last(key) == List.last(source)

  defp fetch_all(conn, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Conn.all_docs(conn, collection_name(key)) do
        {:ok, rows} -> {:cont, {:ok, acc ++ Enum.map(rows, &{key, &1})}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, {:query_error, _}} = err -> {:halt, err}
      end
    end)
  end

  defp collection_name(key), do: Enum.join(key, @separator)

  # Threads a unique, synthetic per-row index through `run_flat/3` (not
  # the tree key itself -- two distinct matched rows can legitimately
  # share the same key) so the post-filter/order/limit survivor list
  # can be mapped back to its own original `{key, row}` pair. Mirrors
  # `scry_document`'s reference `Executor`'s own identical technique.
  defp order_and_limit(matches, query, params) do
    indexed = Enum.with_index(matches)
    lookup = Map.new(indexed, fn {{key, row}, idx} -> {idx, {key, row}} end)

    tagged_rows =
      Enum.map(indexed, fn {{_key, row}, idx} -> Map.put(row, @document_key_field, idx) end)

    marker_query = %{query | select: [{:field, [@document_key_field]}]}

    with {:ok, marker_rows} <- QueryOps.run_flat(tagged_rows, marker_query, params) do
      ordered =
        marker_rows
        |> Enum.to_list()
        |> Enum.map(fn %{@document_key_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp project_all(ordered, select, conn, own_name, params) do
    ordered
    |> Enum.map(fn {key, row} -> project_body(key, row, select, conn, own_name, params) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one already-resolved `{key, row}` against `body` -- plain
  # fields delegate to `Scry.Core.QueryOps.run_flat/3`, a nested `%Scry.
  # Core.Query{}` body item resolves via `resolve_correlated_nested/5`,
  # and `PARENT`/`SIBLINGS`/`ANCESTORS` resolve recursively through this
  # same function, one level relative to `key`. `own_name` is always the
  # *original, top-level* query's own source name, unchanged as this
  # recurses into a pseudo-field's own nested body -- the identical
  # scope limit `scry_document`'s reference `Executor` already states.
  defp project_body(key, row, body, conn, own_name, params) do
    pseudo_items = extract_pseudo_items(body)

    {nested_items, flat_select} =
      body |> strip_pseudo_items() |> Enum.split_with(&is_struct(&1, Query))

    with {:ok, base} <- project_ordinary(row, flat_select, params),
         {:ok, with_nested} <- add_nested_results(base, nested_items, row, conn, own_name, params) do
      resolve_pseudo_items(pseudo_items, with_nested, key, conn, own_name, params)
    end
  end

  defp resolve_pseudo_items([], base, _key, _conn, _own_name, _params), do: {:ok, base}

  defp resolve_pseudo_items(pseudo_items, base, key, conn, own_name, params) do
    Enum.reduce_while(pseudo_items, {:ok, base}, fn item, {:ok, acc} ->
      resolve_one_pseudo_item(item, acc, key, conn, own_name, params)
    end)
  end

  defp resolve_one_pseudo_item({output_key, kind, nested_body}, acc, key, conn, own_name, params) do
    case resolve_pseudo_field(kind, nested_body, key, conn, own_name, params) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, output_key, value)}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp extract_pseudo_items(body_items) do
    Enum.flat_map(body_items, fn
      {:variant, {kind, body}} when kind in [:parent, :siblings, :ancestors] ->
        [{Atom.to_string(kind), kind, body}]

      _other ->
        []
    end)
  end

  defp strip_pseudo_items(body_items) do
    Enum.reject(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      _other -> false
    end)
  end

  defp add_nested_results(base, [], _row, _conn, _own_name, _params), do: {:ok, base}

  defp add_nested_results(base, nested_items, row, conn, own_name, params) do
    Enum.reduce_while(nested_items, {:ok, base}, fn nested, {:ok, acc} ->
      resolve_nested(nested, acc, row, conn, own_name, params)
    end)
  end

  defp resolve_nested(nested, acc, row, conn, own_name, params) do
    fetch_fn = fn q, p -> fetch_and_drain(conn, q, p) end

    case QueryOps.resolve_correlated_nested(nested, row, own_name, params, fetch_fn) do
      {:ok, rows} -> {:cont, {:ok, Map.put(acc, List.last(nested.source), rows)}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp fetch_and_drain(conn, query, params) do
    with {:ok, enumerable} <- execute(conn, query, params) do
      {:ok, Enum.to_list(enumerable)}
    end
  end

  defp project_ordinary(_row, [], _params), do: {:ok, %{}}

  defp project_ordinary(row, select, params) do
    case QueryOps.run_flat([row], %Query{select: select}, params) do
      {:ok, enumerable} ->
        case Enum.to_list(enumerable) do
          [projected] -> {:ok, projected}
          [] -> {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_pseudo_field(:parent, body, key, conn, own_name, params) do
    case parent_key(key) do
      nil -> {:ok, nil}
      parent_key -> project_first(parent_key, body, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:siblings, body, key, conn, own_name, params) do
    parent = parent_key(key)

    with {:ok, names} <- Conn.collection_names(conn) do
      names
      |> Enum.map(&String.split(&1, @separator))
      |> Enum.filter(&(&1 != key and parent_key(&1) == parent))
      |> Enum.sort()
      |> project_all_rows(body, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:ancestors, body, key, conn, own_name, params) do
    key
    |> ancestor_keys()
    |> Enum.reduce_while({:ok, []}, fn ancestor_key, {:ok, acc} ->
      case project_first(ancestor_key, body, conn, own_name, params) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_all_rows(keys, body, conn, own_name, params) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      fetch_and_project_rows(key, body, conn, own_name, params, acc)
    end)
  end

  defp fetch_and_project_rows(key, body, conn, own_name, params, acc) do
    case Conn.all_docs(conn, collection_name(key)) do
      {:ok, rows} -> continue_with_projected(rows, key, body, conn, own_name, params, acc)
      {:error, :not_found} -> {:cont, {:ok, acc}}
      {:error, {:query_error, _}} = err -> {:halt, err}
    end
  end

  defp continue_with_projected(rows, key, body, conn, own_name, params, acc) do
    case project_rows(key, rows, body, conn, own_name, params) do
      {:ok, projected} -> {:cont, {:ok, acc ++ projected}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp project_rows(key, rows, body, conn, own_name, params) do
    rows
    |> Enum.map(fn row -> project_body(key, row, body, conn, own_name, params) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, r} -> r end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  defp project_first(key, body, conn, own_name, params) do
    case Conn.limited_docs(conn, collection_name(key), 1) do
      {:ok, [row | _rest]} -> project_body(key, row, body, conn, own_name, params)
      {:ok, []} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, {:query_error, _}} = err -> err
    end
  end

  defp parent_key([_single]), do: nil
  defp parent_key(key), do: Enum.drop(key, -1)

  defp ancestor_keys(key) when length(key) <= 1, do: []
  defp ancestor_keys(key), do: for(i <- (length(key) - 1)..1//-1, do: Enum.take(key, i))

  @sample_size 100

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  samples up to #{@sample_size} documents from `source`'s own real
  Couchbase collection (`source` is the collection name directly, `__`-
  joined tree-key segments included) and reports every field name
  observed, with a best-effort scalar type inferred from the first
  sampled value seen for it. `nullable: true` unconditionally --
  Couchbase has no schema/required-field concept this package can
  generically introspect, the identical reasoning `scry_engine_
  mongodb_driver`/`scry_engine_couchdb` each already give.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [Scry.Core.EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(%Conn{} = conn, source) do
    case Conn.limited_docs(conn, source, @sample_size) do
      {:ok, []} -> {:error, :not_found}
      {:ok, docs} -> {:ok, fields_from_sample(docs)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:query_error, reason}} -> {:error, {:introspection_error, reason}}
    end
  end

  defp fields_from_sample(docs) do
    docs
    |> Enum.reduce(%{}, fn doc, acc ->
      Map.merge(acc, doc, fn _k, existing, _new -> existing end)
    end)
    |> Enum.map(fn {name, value} ->
      %{name: name, nullable: true, scalar: infer_scalar(value)}
    end)
  end

  defp infer_scalar(value) when is_binary(value), do: :string
  defp infer_scalar(value) when is_integer(value), do: :integer
  defp infer_scalar(value) when is_float(value), do: :float
  defp infer_scalar(value) when is_boolean(value), do: :boolean
  defp infer_scalar(value) when is_map(value) or is_list(value), do: :json
  defp infer_scalar(_other), do: :unknown
end
