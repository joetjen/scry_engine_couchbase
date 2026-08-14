defmodule Scry.Engine.Couchbase.Conn do
  @moduledoc """
  Wraps a reachable Couchbase Server's two separate REST surfaces --
  the Query Service (`query_base_url`, default `http://localhost:8093`,
  N1QL/SQL++ reads and writes) and the Cluster Manager (`mgmt_base_url`,
  default `http://localhost:8091`, bucket/scope/collection
  introspection and management) -- plus one fixed `bucket`/`scope` pair
  and HTTP Basic `auth`. No persistent connection exists to open at all,
  the identical situation `Scry.Engine.CouchDB.Conn`'s own moduledoc
  already documents for CouchDB's own plain, stateless JSON-over-HTTP
  wire protocol (`req`'s own connection pooling, via `Finch`, is managed
  transparently underneath every individual request).

  `bucket`/`scope` together are the fixed context every real Couchbase
  *collection* this package reads/writes sits inside -- the direct
  structural analog of `Scry.Engine.MongoDB.Conn`'s own fixed
  `database`, one level more nested than CouchDB's own bucket-less
  model (a stock CouchDB server has no grouping above "database" at
  all). One real Couchbase collection per tree-position key, `__`-
  joined (`Scry.Engine.Couchbase`'s own moduledoc has the full
  reasoning), lives inside this fixed bucket/scope.

  Every read/write this package issues goes through `n1ql/3`/
  `collection_names/1`/`create_collection/2`/`insert_document/3` here,
  never a raw `Req.*` call directly from `Scry.Engine.Couchbase` itself.
  """

  @type t :: %__MODULE__{
          query_base_url: String.t(),
          mgmt_base_url: String.t(),
          bucket: String.t(),
          scope: String.t(),
          auth: {String.t(), String.t()}
        }

  @enforce_keys [:bucket, :auth]
  defstruct query_base_url: "http://localhost:8093",
            mgmt_base_url: "http://localhost:8091",
            bucket: nil,
            scope: "scry",
            auth: nil

  @doc """
  Wraps `bucket` (required, no default -- unlike CouchDB's own
  implicit-database-per-tree-key model, a Couchbase bucket is a real,
  explicitly-provisioned resource with its own memory quota, confirmed
  directly: there's no "just start writing" fallback), `scope`
  (default `"scry"`, itself created explicitly the same way), `auth`
  (required `{username, password}` -- every real Couchbase Server needs
  one, confirmed directly, an unauthenticated request against a real
  container returns a clean `401`), and the two base URLs (defaulted to
  a stock local single-node container's own two exposed ports).
  """
  @spec open(keyword()) :: {:ok, t()}
  def open(opts \\ []) do
    {:ok,
     %__MODULE__{
       query_base_url:
         opts
         |> Keyword.get(:query_base_url, "http://localhost:8093")
         |> String.trim_trailing("/"),
       mgmt_base_url:
         opts |> Keyword.get(:mgmt_base_url, "http://localhost:8091") |> String.trim_trailing("/"),
       bucket: Keyword.fetch!(opts, :bucket),
       scope: Keyword.get(opts, :scope, "scry"),
       auth: Keyword.fetch!(opts, :auth)
     }}
  end

  @doc """
  Runs `statement` (a N1QL/SQL++ string) with `args` bound as named
  parameters -- each `k => v` pair in `args` is sent as its own real
  top-level `"$k": v` request field (confirmed directly: Couchbase's
  own REST API binds a `$name` placeholder to a top-level `"$name"`
  request key, *not* a nested `args`/`$args` wrapper object -- an
  earlier draft of this function sent the whole map under a literal
  `"$args"` key, which silently left every real `$name` placeholder
  unbound, `"No value for named parameter ..."`, caught by a real,
  reproduced test failure, not assumed from the docs).

  **Always forces `scan_consistency: "request_plus"`** -- a real,
  confirmed, load-bearing finding: Couchbase's own default consistency
  (`not_bounded`) is genuinely eventually-consistent against the
  indexer, confirmed directly, a document inserted immediately before a
  `SELECT` with no explicit consistency override came back with zero
  rows. `request_plus` blocks until the index has caught up to the
  request's own start time, the same "correctness over raw latency"
  choice this whole family already makes by default (no adapter here
  opts into an eventually-consistent read path silently).

  **A second real finding, genuinely surprising**: an application-level
  N1QL failure (an unbound parameter, a missing keyspace, ...) can come
  back inside a real HTTP `200` -- confirmed directly, the response
  body still carries both a `"results": []` key *and* a fatal
  `"errors"` array in the same 200 response, unlike every other REST-
  backed adapter in this family (`scry_engine_elasticsearch`/`scry_
  engine_couchdb`/`scry_engine_loki`/`scry_engine_influxdb`/`scry_
  engine_arangodb`), all of which signal a query-level failure via a
  non-2xx status. `n1ql/3` checks for `"errors"` *before* trusting a
  200's own `"results"` key for exactly this reason -- error code
  `12003` ("Keyspace not found", a missing collection) normalizes to
  `{:error, :not_found}`; every other error normalizes to `{:error,
  {:query_error, term()}}`.
  """
  @spec n1ql(t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, {:query_error, term()}}
  def n1ql(%__MODULE__{query_base_url: base_url, auth: auth}, statement, args \\ %{}) do
    named_params = Map.new(args, fn {k, v} -> {"$#{k}", v} end)
    body = Map.merge(%{statement: statement, scan_consistency: "request_plus"}, named_params)

    case Req.post(base_url <> "/query/service", auth: {:basic, basic_auth(auth)}, json: body) do
      # A real, confirmed finding: the Query Service can answer with a
      # real HTTP 200 whose *body* still carries a fatal `"errors"`
      # array (`"results"` present too, always `[]` in that case) --
      # an application-level failure, not a transport one, so `errors`
      # must be checked *before* trusting a 200's own `"results"` key.
      {:ok, %Req.Response{body: %{"errors" => errors}}} -> normalize_error(errors)
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} -> {:ok, results}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp normalize_error([%{"code" => 12_003} | _]), do: {:error, :not_found}
  defp normalize_error(errors), do: {:error, {:query_error, errors}}

  @doc """
  Every document in collection `name` (a plain, flat map -- there is no
  implicit identity field to strip here at all, unlike `_id`/`_rev` in
  `Scry.Engine.CouchDB.Conn`/`Scry.Engine.MongoDB.Conn`: this package
  only ever selects `d.*`, never `META(d).id`, so nothing but the
  document's own real fields ever comes back). `{:error, :not_found}`
  when `name` doesn't exist at all (N1QL error `12003`), the identical
  divergence-from-MongoDB `Scry.Engine.CouchDB.Conn.all_docs/2` already
  states: a Couchbase collection must be explicitly created before
  anything can be read from it, confirmed directly.
  """
  @spec all_docs(t(), String.t()) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, {:query_error, term()}}
  def all_docs(%__MODULE__{bucket: bucket, scope: scope} = conn, name) do
    n1ql(conn, "SELECT d.* FROM `#{bucket}`.`#{scope}`.`#{name}` AS d")
  end

  @doc "Up to `limit` documents from collection `name` -- `PARENT`/`ANCESTORS`'s own \"first row only\" simplification uses `limit: 1`; `describe_source/2` uses a larger sample."
  @spec limited_docs(t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, {:query_error, term()}}
  def limited_docs(%__MODULE__{bucket: bucket, scope: scope} = conn, name, limit) do
    n1ql(conn, "SELECT d.* FROM `#{bucket}`.`#{scope}`.`#{name}` AS d LIMIT #{limit}")
  end

  @doc """
  Every real collection name in `conn`'s own fixed `bucket`/`scope` --
  `DEEP`'s own cross-collection matching, and `PARENT`/`SIBLINGS`/
  `ANCESTORS`'s own relative-collection resolution, both need the full
  set to filter against, the identical shape `Scry.Engine.CouchDB.Conn.
  all_dbs/1`/`Scry.Engine.ArangoDB.Conn.collection_names/2` already
  have. `{:ok, []}` (not an error) when the scope itself doesn't exist
  yet -- callers here always pre-create it, but an empty result is the
  honest answer either way.
  """
  @spec collection_names(t()) :: {:ok, [String.t()]} | {:error, {:query_error, term()}}
  def collection_names(%__MODULE__{bucket: bucket, scope: scope} = conn) do
    case mgmt_get(conn, "/pools/default/buckets/#{bucket}/scopes") do
      {:ok, %{"scopes" => scopes}} ->
        names =
          scopes
          |> Enum.find(%{"collections" => []}, &(&1["name"] == scope))
          |> Map.fetch!("collections")
          |> Enum.map(& &1["name"])

        {:ok, names}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates collection `name` in `conn`'s own fixed bucket/scope,
  idempotent (a `400` naming an already-existing collection is treated
  the same as a fresh success).

  **Blocks until the collection is genuinely queryable, not just
  created** -- a real, confirmed finding: the Cluster Manager's own
  collection-creation call returns a real `200` synchronously, but the
  Query Service's own keyspace metadata cache can lag behind it by a
  similar short window, confirmed directly (an `INSERT`/`SELECT`
  issued immediately after a `200` create response intermittently
  fails with error `12003`, "Keyspace not found", under real
  concurrent load). `create_collection/2` polls a cheap `SELECT`
  against the new collection until it stops 12003-ing, the identical
  "confirm the real state transition rather than assume a fixed delay"
  posture `Scry.Engine.Couchbase.Conn.n1ql/3`'s own `request_plus`
  consistency choice already takes for reads, and every caller of this
  function -- library and test code alike -- gets a genuinely usable
  collection back, not a race.
  """
  @spec create_collection(t(), String.t()) :: :ok | {:error, {:query_error, term()}}
  def create_collection(%__MODULE__{bucket: bucket, scope: scope} = conn, name) do
    case mgmt_post(conn, "/pools/default/buckets/#{bucket}/scopes/#{scope}/collections", %{
           "name" => name
         }) do
      {:ok, _} ->
        wait_until_queryable(conn, name)

      {:error, {:query_error, %{"errors" => errors}}} = error ->
        already_exists_or(conn, name, errors, error)

      {:error, _} = error ->
        error
    end
  end

  defp already_exists_or(conn, name, errors, error) do
    if errors |> Map.values() |> Enum.any?(&String.contains?(to_string(&1), "already exists")) do
      wait_until_queryable(conn, name)
    else
      error
    end
  end

  defp wait_until_queryable(conn, name, attempts \\ 50)

  defp wait_until_queryable(_conn, name, 0),
    do: {:error, {:query_error, {:collection_never_became_queryable, name}}}

  defp wait_until_queryable(conn, name, attempts) do
    case limited_docs(conn, name, 1) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        Process.sleep(50)
        wait_until_queryable(conn, name, attempts - 1)

      {:error, _} = error ->
        error
    end
  end

  @doc "Inserts `doc` (a plain map) into collection `name` under a fresh server-generated key."
  @spec insert_document(t(), String.t(), map()) :: :ok | {:error, {:query_error, term()}}
  def insert_document(%__MODULE__{bucket: bucket, scope: scope} = conn, name, doc) do
    statement =
      "INSERT INTO `#{bucket}`.`#{scope}`.`#{name}` (KEY, VALUE) VALUES (UUID(), $doc)"

    case n1ql(conn, statement, %{doc: doc}) do
      {:ok, _rows} -> :ok
      {:error, _} = error -> error
    end
  end

  defp mgmt_get(%__MODULE__{mgmt_base_url: base_url, auth: auth}, path) do
    case Req.get(base_url <> path, auth: {:basic, basic_auth(auth)}) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{body: body}} -> {:error, {:query_error, body}}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp mgmt_post(%__MODULE__{mgmt_base_url: base_url, auth: auth}, path, form) do
    case Req.post(base_url <> path, auth: {:basic, basic_auth(auth)}, form: form) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{body: body}} -> {:error, {:query_error, body}}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp basic_auth({username, password}), do: username <> ":" <> password
end
