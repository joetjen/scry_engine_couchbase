# scry_engine_couchbase

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [Couchbase](https://www.couchbase.com/), via
[`req`](https://hex.pm/packages/req) -- not a dedicated Couchbase
client. Replaces `scry_document`'s own in-memory reference
implementation (`Scry.Document.Executor`) with genuine
bucket/scope/collection-and-N1QL-backed `DEEP`/`PARENT`/`SIBLINGS`/
`ANCESTORS` execution against a *third* real document store, after
[`scry_engine_mongodb_driver`](https://github.com/joetjen/scry_engine_mongodb_driver)
and
[`scry_engine_couchdb`](https://github.com/joetjen/scry_engine_couchdb)
-- and, not incidentally, `scry_reldoc`'s own long-deferred storage
adapter: impl_spec.md §6 had named Couchbase there from the start,
deferred as lower marginal value than `scry_docgraph`'s own ArangoDB
landing, since `scry_reldoc` is a thin delegate to `scry_document`
already validated twice over. Confirming the correlated-nested-`SELECT`
composition holds against a genuinely different backend is this
package's own real, distinct contribution -- see `test/scry/engine/
couchbase/reldoc_test.exs`.

Source: <https://github.com/joetjen/scry_engine_couchbase>. Specs live
in the separate [`scry`](https://github.com/joetjen/scry) repository;
the behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Couchbase.Conn.open(bucket: "mybucket", auth: {"Administrator", "password123"})

{:ok, query} = Scry.Core.parse(~s(SELECT library.catalog.fiction { title, PARENT { name } }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Couchbase, conn)
rows = Scry.Core.Cursor.to_list(cursor)
```

Creating buckets/scopes/collections/documents is entirely the caller's
own job -- this package is schema-agnostic and issues nothing but N1QL
reads/writes plus `GET /pools/default/buckets/{bucket}/scopes`
introspection. `Conn.create_collection/2`/`Conn.insert_document/3` are
provided for exactly this, mirroring every other document adapter in
this family; bucket/scope provisioning is a one-time, cluster-level
admin operation this package deliberately leaves out of its own public
API (see below).

### Local development / running the test suite

A fresh Couchbase Server container needs real, one-time cluster
provisioning before it's usable at all -- unlike every other backend in
this family, there's no "just start writing" default:

```sh
docker run -d --name scry-couchbase \
  -p 8091-8096:8091-8096 -p 11210:11210 \
  couchbase:community-7.6.2

# wait for the web console to answer, then:
curl -s -X POST http://localhost:8091/pools/default \
  -d 'memoryQuota=2048' -d 'indexMemoryQuota=512'
curl -s -X POST http://localhost:8091/node/controller/setupServices \
  -d 'services=kv%2Cn1ql%2Cindex'
curl -s -X POST http://localhost:8091/settings/web \
  -d 'username=Administrator' -d 'password=password123' -d 'port=SAME'
curl -s -u Administrator:password123 -X POST http://localhost:8091/settings/indexes \
  -d 'storageMode=forestdb'
```

(`forestdb`, not `plasma` -- confirmed directly, the Community Edition
build only accepts `forestdb` as its own index storage mode.)

The test suite provisions its own buckets/scopes per run
(`test/support/couchbase_test_support.ex`), so no bucket needs
creating by hand.

## No dedicated driver -- confirmed, not assumed

No official Couchbase SDK covers Elixir or Erlang at all -- Couchbase's
own supported-SDK list stops at .NET/PHP/Ruby/Python/C/Node.js/Java/
Go/Scala. Every community option found (`gauc`, two independent
`cberl` forks, `couchie`) is confirmed multi-year stale (last release/
commit 2017-2023, none actively maintained) -- the same disqualifying
bar `bolt_sips`/`couchdb_connector`/`instream` already failed elsewhere
in this family, just with no live alternative to fall back to at all
this time. Couchbase's own Query Service exposes a plain HTTP endpoint
for N1QL/SQL++ (`POST :8093/query/service`) -- the identical "no
client-specific protocol to speak" situation `scry_engine_
elasticsearch`/`scry_engine_couchdb`/`scry_engine_loki`/`scry_engine_
influxdb` already resolved with `req`, applied here for the same
reason.

## Bucket + scope, fixed at `Conn.open/1` time; collection-per-tree-key, joined with `__`

Couchbase's own data model nests one level deeper than either prior
document adapter in this family: bucket > scope > collection >
document, not MongoDB's flat database > collection or CouchDB's
server > database. `bucket`/`scope` together play the identical
fixed-context role `Scry.Engine.MongoDB.Conn`'s own `database` plays
-- set once at `Conn.open/1` time, never derived from a query's own
source path -- and one real Couchbase *collection* per tree-position
key, segments joined with `__` (not `.`: Couchbase's own collection-
naming rule disallows a literal `.` outright, confirmed directly, the
identical restriction `scry_engine_couchdb`/`scry_engine_arangodb`
already found for their own database/collection names), lives inside
that fixed bucket/scope.

## Two real, confirmed N1QL REST findings

- **Named-parameter binding is a flat top-level field, not a nested
  wrapper.** A `$name` placeholder in a N1QL statement binds to a real
  top-level `"$name"` request field -- confirmed the hard way, an
  earlier draft sent the whole parameter map under a literal `"$args"`
  key, which silently left every placeholder unbound
  (`"No value for named parameter ..."`), caught by a real,
  reproduced test failure.
- **An application-level query failure can arrive inside a real HTTP
  200.** Confirmed directly: an unbound parameter or a missing
  keyspace can come back with `status: 200` and a body carrying both
  `"results": []` *and* a fatal `"errors"` array -- unlike every other
  REST-backed adapter in this family, all of which signal a query-level
  failure via a non-2xx status. `Conn.n1ql/3` checks for `"errors"`
  before trusting a 200's own `"results"` key for exactly this reason.

## A real, load-bearing consistency finding

Couchbase's own default N1QL scan consistency (`not_bounded`) is
genuinely eventually-consistent against its own global secondary
indexer -- confirmed directly, a document inserted immediately before
an unqualified `SELECT` came back with zero rows. `Conn.n1ql/3` always
forces `scan_consistency: "request_plus"`, blocking until the index
has caught up to the request's own start time.

A second, confirmed-for-this-version-specifically finding: unlike
older Couchbase releases (which require an explicit `CREATE PRIMARY
INDEX` before any unfiltered scan), Couchbase Server 7.6's own
index-free full-collection-scan capability means this package issues
no index-management calls at all -- confirmed directly against a real
`couchbase:community-7.6.2` container.

A third, genuinely surprising finding: even under `request_plus`, a
freshly-created collection can briefly 12003 ("Keyspace not found")
against the Query Service's own metadata cache even after the Cluster
Manager's own creation call returns `200` -- `Conn.create_collection/2`
polls a cheap read against the new collection until it stops 12003-ing
before returning, so every caller (library and test code alike) gets a
genuinely usable collection back, not a race.

## No pushdown at all -- everything but hierarchy resolution is generic

The identical posture `scry_engine_mongodb_driver`/`scry_engine_
couchdb` already establish, for the identical reason: every one of
`WHERE`/`GROUP BY`/aggregates/`HAVING`/`DISTINCT`/`ORDER BY`/`LIMIT`/
`OFFSET`/projection applies generically via `Scry.Core.QueryOps.
run_flat/3`, never translated into N1QL. The only real adapter-specific
work, mirroring the reference `Executor`'s own architecture exactly, is
knowing *which collection(s)* to read.

## A missing collection is an error, matching the reference

The identical divergence-from-MongoDB `scry_engine_couchdb` already
states, confirmed again here on independent grounds: a Couchbase
collection must be explicitly created before anything can be read from
it -- confirmed directly, a `SELECT` against a collection that was
never created returns N1QL error `12003`, not an empty result. So for
an ordinary (non-`DEEP`) source, this package matches the reference's
own strict `{:error, {:query_error, {:no_such_source, _}}}` behavior.

## No document-identity field ever needs stripping

Unlike `_id`/`_rev` in `scry_engine_couchdb`/`_id` in `scry_engine_
mongodb_driver` (both always present, always stripped), this package
only ever projects `d.*` in its own N1QL `SELECT`, never `META(d).id`,
so nothing but a document's own real fields is ever returned in the
first place.

## Parity testing against the reference

AGENTS.md's "Parity between multiple implementations" rule applies
directly: `test/scry/engine/couchbase/parity_test.exs` reuses `scry_
document`'s own fixture verbatim, parses each query text once, and
runs it against both a real Couchbase container and the reference's
own in-memory `Conn`, asserting the results agree. Three of its own
multi-row cases needed an explicit `ORDER BY title` added -- unlike
`scry_engine_couchdb`'s own identical fixture/queries, a Couchbase
`SELECT` with no `ORDER BY` has no row-order guarantee at all, and
`KEY UUID()`-generated document keys give no coincidental
insertion-order stability the way CouchDB's own sequential document
IDs happened to.

`test/scry/engine/couchbase/reldoc_test.exs` is this package's own
distinct contribution beyond parity: it parses via `Scry.Reldoc.
parse/1` and runs the result through `Scry.Core.Executor.run/4`
against this real adapter directly, proving the relational+document
composite's own correlated-nested-`SELECT` + `PARENT` composition
holds against a real backend, not just the in-memory reference.

## Installation

```elixir
def deps do
  [
    {:scry_engine_couchbase, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_couchbase>.
