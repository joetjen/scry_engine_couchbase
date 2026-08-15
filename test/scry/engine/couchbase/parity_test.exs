defmodule Scry.Engine.Couchbase.ParityTest do
  @moduledoc """
  AGENTS.md's "Parity between multiple implementations" rule, applied
  directly: `scry_document`'s own reference `Scry.Document.Executor`
  and this package's `Scry.Engine.Couchbase` (a real Couchbase-backed
  adapter) are two implementations of the identical `DEEP`/`PARENT`/
  `SIBLINGS`/`ANCESTORS` semantics -- the same
  posture already established for `scry_graph`/`scry_engine_neo4j` and
  `scry_document`/`scry_engine_mongodb_driver`/`scry_engine_couchdb`.
  This suite parses one query text *once* (`Scry.Document.parse/1`),
  then runs the exact same `%Scry.Core.Query{}` against a byte-for-byte
  identical fixture in both a real Couchbase container and the
  reference's own in-memory `Scry.Document.Conn`, and asserts the
  results agree.

  **A real, confirmed ordering finding, unlike `scry_engine_couchdb`'s
  own identical fixture/queries**: three of this suite's own multi-row
  cases needed an explicit `ORDER BY title` added to their own query
  text (the reference itself is unaffected either way, since `Scry.
  Document.Executor` already applies whatever ordering the query asks
  for) -- confirmed directly, a real Couchbase `SELECT` with no
  `ORDER BY` has no row-order guarantee at all, and `KEY UUID()`-
  generated document keys give this package's own real backend no
  coincidental insertion-order stability the way CouchDB's own
  (largely sequential) document IDs happened to give its adapter's
  identical parity suite. A real backend difference, not a bug.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.Cursor
  alias Scry.Document.Conn, as: RefConn
  alias Scry.Document.Executor, as: RefEngine
  alias Scry.Engine.Couchbase, as: RealEngine
  alias Scry.Engine.Couchbase.Conn, as: RealConn
  alias Scry.Engine.Couchbase.TestSupport

  @bucket "scry_parity_test"
  @auth {"Administrator", "password123"}

  setup_all do
    {:ok, real_conn} = RealConn.open(bucket: @bucket, auth: @auth)
    TestSupport.reset_bucket!(@bucket, @auth)
    seed_real!(real_conn)
    %{real_conn: real_conn, ref_conn: fixture_ref_conn()}
  end

  # The identical fixture `scry_document`'s own `Scry.Document.
  # ExecutorTest`'s "PARENT/SIBLINGS/ANCESTORS" describe block uses,
  # node for node -- the same fixture `scry_engine_mongodb_driver`'s/
  # `scry_engine_couchdb`'s own parity suites already reuse too.
  defp fixture_ref_conn do
    RefConn.new(%{
      ["library"] => [%{"name" => "Main", "region" => "north"}],
      ["library", "fiction"] => [%{"name" => "Fiction"}],
      ["library", "nonfiction"] => [%{"name" => "Non-Fiction"}],
      ["library", "fiction", "book"] => [
        %{"title" => "Dune"},
        %{"title" => "Foundation"}
      ]
    })
  end

  defp seed_real!(conn) do
    create!(conn, "library", %{"name" => "Main", "region" => "north"})
    create!(conn, "library__fiction", %{"name" => "Fiction"})
    create!(conn, "library__nonfiction", %{"name" => "Non-Fiction"})
    create!(conn, "library__fiction__book", %{"title" => "Dune"})
    create!(conn, "library__fiction__book", %{"title" => "Foundation"})
  end

  defp create!(conn, name, doc) do
    :ok = RealConn.create_collection(conn, name)
    :ok = RealConn.insert_document(conn, name, doc)
  end

  defp run_both(source, ref_conn, real_conn) do
    {:ok, query} = Scry.Document.parse(source)
    {:ok, ref_cursor} = RefEngine.run(query, ref_conn)
    {:ok, real_enumerable} = RealEngine.execute(real_conn, query, %{})
    {Cursor.to_list(ref_cursor), Enum.to_list(real_enumerable)}
  end

  for {label, query_text} <- [
        {"no DEEP, exact key match", ~s(SELECT library.fiction.book ORDER BY title { title })},
        {"DEEP, single-segment source", ~s(SELECT book DEEP ORDER BY title { title })},
        {"PARENT resolves one level up",
         ~s(SELECT library.fiction.book ORDER BY title { title, PARENT { name } })},
        {"PARENT is nil at the root", ~s(SELECT library { name, PARENT { name } })},
        {"SIBLINGS resolves the sibling collection's own rows",
         ~s(SELECT library.fiction { name, SIBLINGS { name } })},
        {"ANCESTORS returns one row per level, nearest first",
         ~s(SELECT library.fiction.book WHERE title = "Dune" { title, ANCESTORS { name } })},
        {"nesting PARENT inside PARENT wraps rather than flattening",
         ~s(SELECT library.fiction.book WHERE title = "Dune" { PARENT { PARENT { name } } })},
        {"PARENT/SIBLINGS/ANCESTORS together in one query",
         ~s(SELECT library.fiction { name, PARENT { name }, SIBLINGS { name }, ANCESTORS { name } })},
        {"ordinary WHERE/ORDER BY/LIMIT, no pseudo-field at all",
         ~s(SELECT library.fiction.book ORDER BY title LIMIT 1 { title })}
      ] do
    test "#{label} -- reference and real engine agree", %{
      real_conn: real_conn,
      ref_conn: ref_conn
    } do
      {ref_rows, real_rows} = run_both(unquote(query_text), ref_conn, real_conn)
      assert ref_rows == real_rows
    end
  end
end
