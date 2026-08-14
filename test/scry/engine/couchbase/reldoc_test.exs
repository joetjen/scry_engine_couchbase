defmodule Scry.Engine.Couchbase.RelDocTest do
  @moduledoc """
  This package's own genuinely distinct contribution over `scry_engine_
  mongodb_driver`/`scry_engine_couchdb` (both of which already validate
  `scry_document` itself twice over): proving `scry_reldoc`'s own
  relational+document composite -- a correlated nested `SELECT` (Scry's
  own `JOIN` equivalent) composed in the *same body* as `PARENT` --
  holds against a *real* backend, not just the in-memory reference
  `Scry.Reldoc.ReldocTest` already exercises. `scry_reldoc` has no
  execution logic of its own at all (`Scry.Reldoc.Executor.run/3` is a
  direct delegation to `Scry.Document.Executor.run/3`), so this suite
  parses via `Scry.Reldoc.parse/1` (identical to `Scry.Document.
  parse/1`, unchanged) and runs the result through `Scry.Core.Executor.
  run/4` against `Scry.Engine.Couchbase` directly -- the same dispatch
  path any real `Scry.Core.EngineBehaviour` adapter takes, `Scry.Reldoc.
  Executor.run/3`'s own reference-`Conn`-only signature bypassed
  entirely, the identical reasoning that signature's own moduledoc
  documents.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor}
  alias Scry.Engine.Couchbase, as: RealEngine
  alias Scry.Engine.Couchbase.Conn, as: RealConn
  alias Scry.Engine.Couchbase.TestSupport

  @bucket "scry_reldoc_test"
  @auth {"Administrator", "password123"}

  setup_all do
    {:ok, conn} = RealConn.open(bucket: @bucket, auth: @auth)
    TestSupport.reset_bucket!(@bucket, @auth)
    seed!(conn)
    %{conn: conn}
  end

  defp seed!(conn) do
    create!(conn, "catalog", %{"name" => "Catalog"})
    create!(conn, "catalog__fiction", %{"id" => 1, "title" => "Book One"})
    create!(conn, "catalog__fiction", %{"id" => 2, "title" => "Book Two"})
    create!(conn, "reviews", %{"book_id" => 1, "stars" => 5})
    create!(conn, "reviews", %{"book_id" => 2, "stars" => 3})
  end

  defp create!(conn, name, doc) do
    :ok = RealConn.create_collection(conn, name)
    :ok = RealConn.insert_document(conn, name, doc)
  end

  test "a correlated nested SELECT composes correctly alongside PARENT, in the same body, against a real Couchbase backend",
       %{conn: conn} do
    {:ok, query} =
      Scry.Reldoc.parse("""
      SELECT catalog.fiction ORDER BY id { title,
        PARENT { name },
        SELECT reviews WHERE book_id = fiction.id { stars }
      }
      """)

    assert {:ok, cursor} = Executor.run(query, RealEngine, conn)
    rows = Cursor.to_list(cursor)

    assert rows == [
             %{
               "title" => "Book One",
               "parent" => %{"name" => "Catalog"},
               "reviews" => [%{"stars" => 5}]
             },
             %{
               "title" => "Book Two",
               "parent" => %{"name" => "Catalog"},
               "reviews" => [%{"stars" => 3}]
             }
           ]
  end

  test "an ordinary query with no pseudo-field at all still works, unaffected", %{conn: conn} do
    {:ok, query} = Scry.Reldoc.parse("SELECT catalog.fiction ORDER BY id { title }")
    assert {:ok, cursor} = Executor.run(query, RealEngine, conn)

    assert Cursor.to_list(cursor) == [
             %{"title" => "Book One"},
             %{"title" => "Book Two"}
           ]
  end
end
