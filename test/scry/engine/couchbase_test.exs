defmodule Scry.Engine.CouchbaseTest do
  @moduledoc """
  `Scry.Engine.Couchbase` -- confirms `execute/3` answers an ordinary
  flat query (no `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS`) entirely via
  `Scry.Core.QueryOps.run_flat/3` over a real Couchbase collection's own
  documents, that `DEEP` matches across every real collection sharing
  the right first/last name segment, that `PARENT`/`SIBLINGS`/
  `ANCESTORS` resolve against real sibling/ancestor collections, that
  nesting one pseudo-field inside another wraps rather than flattening,
  that a pseudo-field/nested `SELECT` combined with `GROUP BY`
  declines, that `%Scry.Core.CombinedQuery{}`/a `WITH`-bound source both
  resolve via `Scry.Core.QueryOps.run_document/4`, and that an ordinary
  (non-`DEEP`) source naming a collection that was never created is a
  clear error, matching the reference's own strict behavior and
  `scry_engine_couchdb`'s own precedent -- all against a real
  `couchbase:community-7.6.2` container, not just plausible-looking
  output.

  **Requires a real, reachable Couchbase Server instance, already
  cluster-initialized** (memory quotas set, services enabled, admin
  user created, index storage mode set) -- see this package's own
  README for the full one-time provisioning sequence. Runs
  `async: false` -- every test shares one real bucket/scope and a
  small, fixed set of collections, dropped and rebuilt in `setup_all`.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{CombinedQuery, Query}
  alias Scry.Engine.Couchbase, as: Engine
  alias Scry.Engine.Couchbase.Conn
  alias Scry.Engine.Couchbase.TestSupport

  @bucket "scry_engine_test"
  @auth {"Administrator", "password123"}

  setup_all do
    {:ok, conn} = Conn.open(bucket: @bucket, auth: @auth)
    TestSupport.reset_bucket!(@bucket, @auth)
    seed!(conn)
    %{conn: conn}
  end

  defp seed!(conn) do
    create!(conn, "library", %{"id" => 1, "name" => "Main", "region" => "north"})
    create!(conn, "library__fiction", %{"name" => "Fiction"})
    create!(conn, "library__nonfiction", %{"name" => "Non-Fiction"})

    create!(conn, "library__fiction__book", %{"id" => 1, "title" => "Dune", "year" => 1965})
    create!(conn, "library__fiction__book", %{"id" => 2, "title" => "Foundation", "year" => 1951})

    create!(conn, "other__book", %{"title" => "Wrong Root"})
    create!(conn, "app__notes", %{"library_id" => 1, "text" => "important"})
    create!(conn, "app__reviews", %{"book_id" => 1, "stars" => 5})
  end

  defp create!(conn, name, doc) do
    :ok = Conn.create_collection(conn, name)
    :ok = Conn.insert_document(conn, name, doc)
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list()}
  defp materialize(other), do: other

  describe "no DEEP -- exact collection match, delegated to Scry.Core.QueryOps.run_flat/3" do
    test "matches only the literal collection", %{conn: conn} do
      query = %Query{source: ["library"], select: [{:field, ["name"]}]}
      assert {:ok, [%{"name" => "Main"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a collection that was never created is a clear error, not an empty result", %{
      conn: conn
    } do
      query = %Query{source: ["nonexistent"], select: [{:field, ["name"]}]}

      assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
               materialize(Engine.execute(conn, query, %{}))
    end

    test "ordinary WHERE/ORDER BY/LIMIT still work", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :gt, ["year"], 1960}],
        select: [{:field, ["title"]}]
      }

      assert {:ok, [%{"title" => "Dune"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "GROUP BY/aggregate works generically", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction", "book"],
        select: [{:computed, "total", {:call, "count", [{:field, ["title"]}]}}]
      }

      assert {:ok, [%{"total" => 2}]} = materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "DEEP -- matches across every real collection sharing first/last name segments" do
    test "matches both a direct child and a deeply-nested descendant", %{conn: conn} do
      query = %Query{
        source: ["library", "book"],
        variant: %{select_ep1a: :deep},
        select: [{:field, ["title"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["title"]) |> Enum.sort() == ["Dune", "Foundation"]
    end

    test "never matches a collection with a different first segment", %{conn: conn} do
      query = %Query{
        source: ["library", "book"],
        variant: %{select_ep1a: :deep},
        select: [{:field, ["title"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      refute "Wrong Root" in Enum.map(rows, & &1["title"])
    end

    test "a single-segment source only constrains the last segment", %{conn: conn} do
      query = %Query{
        source: ["book"],
        variant: %{select_ep1a: :deep},
        select: [{:field, ["title"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["title"]) |> Enum.sort() == ["Dune", "Foundation", "Wrong Root"]
    end

    test "without DEEP, the same multi-segment source only matches the literal collection", %{
      conn: conn
    } do
      query = %Query{source: ["library", "book"], select: [{:field, ["title"]}]}

      assert {:error, {:query_error, {:no_such_source, ["library", "book"]}}} =
               materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "PARENT/SIBLINGS/ANCESTORS" do
    test "PARENT resolves to the row one level up, projected through its own body", %{
      conn: conn
    } do
      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :eq, ["title"], "Dune"}],
        select: [{:field, ["title"]}, {:variant, {:parent, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"title" => "Dune", "parent" => %{"name" => "Fiction"}}
    end

    test "PARENT is nil at the root", %{conn: conn} do
      query = %Query{
        source: ["library"],
        select: [{:field, ["name"]}, {:variant, {:parent, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"name" => "Main", "parent" => nil}
    end

    test "SIBLINGS resolves every row in every sibling collection, excluding the row's own collection",
         %{conn: conn} do
      query = %Query{
        source: ["library"],
        select: [{:field, ["name"]}, {:variant, {:siblings, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"name" => "Main", "siblings" => []}

      query2 = %Query{
        source: ["library", "fiction"],
        select: [{:field, ["name"]}, {:variant, {:siblings, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row2]} = materialize(Engine.execute(conn, query2, %{}))
      assert row2 == %{"name" => "Fiction", "siblings" => [%{"name" => "Non-Fiction"}]}
    end

    test "ANCESTORS returns one row per level, nearest first, root last", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :eq, ["title"], "Dune"}],
        select: [{:field, ["title"]}, {:variant, {:ancestors, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["ancestors"] == [%{"name" => "Fiction"}, %{"name" => "Main"}]
    end

    test "ANCESTORS is an empty list at the root", %{conn: conn} do
      query = %Query{
        source: ["library"],
        select: [{:field, ["name"]}, {:variant, {:ancestors, [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"name" => "Main", "ancestors" => []}
    end

    test "nesting PARENT inside PARENT wraps rather than flattening", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :eq, ["title"], "Dune"}],
        select: [
          {:variant, {:parent, [{:variant, {:parent, [{:field, ["name"]}]}}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"parent" => %{"parent" => %{"name" => "Main"}}}
    end

    test "PARENT/SIBLINGS/ANCESTORS together in one query", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction"],
        select: [
          {:field, ["name"]},
          {:variant, {:parent, [{:field, ["name"]}]}},
          {:variant, {:siblings, [{:field, ["name"]}]}},
          {:variant, {:ancestors, [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))

      assert row == %{
               "name" => "Fiction",
               "parent" => %{"name" => "Main"},
               "siblings" => [%{"name" => "Non-Fiction"}],
               "ancestors" => [%{"name" => "Main"}]
             }
    end
  end

  describe "a nested correlated SELECT sibling of an ordinary field" do
    test "correlates to the top-level source's own row", %{conn: conn} do
      nested = %Query{
        source: ["app", "notes"],
        wheres: [{:cmp, :eq, ["library_id"], {:field, ["library", "id"]}}],
        select: [{:field, ["text"]}]
      }

      query = %Query{
        source: ["library"],
        select: [{:field, ["name"]}, nested]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["name"] == "Main"
      assert row["notes"] == [%{"text" => "important"}]
    end

    test "composes correctly alongside PARENT, in the same body", %{conn: conn} do
      nested = %Query{
        source: ["app", "reviews"],
        wheres: [{:cmp, :eq, ["book_id"], {:field, ["book", "id"]}}],
        select: [{:field, ["stars"]}]
      }

      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :eq, ["title"], "Dune"}],
        select: [
          {:field, ["title"]},
          {:variant, {:parent, [{:field, ["name"]}]}},
          nested
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))

      assert row == %{
               "title" => "Dune",
               "parent" => %{"name" => "Fiction"},
               "reviews" => [%{"stars" => 5}]
             }
    end

    test "an unmatched correlation yields an empty nested list, not an error", %{conn: conn} do
      nested = %Query{
        source: ["app", "reviews"],
        wheres: [{:cmp, :eq, ["book_id"], {:field, ["book", "id"]}}],
        select: [{:field, ["stars"]}]
      }

      query = %Query{
        source: ["library", "fiction", "book"],
        wheres: [{:cmp, :eq, ["title"], "Foundation"}],
        select: [{:field, ["title"]}, nested]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"title" => "Foundation", "reviews" => []}
    end
  end

  describe "GROUP BY scope limits" do
    test "a pseudo-field alongside GROUP BY declines explicitly", %{conn: conn} do
      query = %Query{
        source: ["library", "fiction", "book"],
        group_bys: [["year"]],
        select: [{:field, ["year"]}, {:variant, {:parent, [{:field, ["name"]}]}}]
      }

      assert {:error, {:unsupported, :pseudo_field_with_group_by}} =
               materialize(Engine.execute(conn, query, %{}))
    end

    test "an ordinary GROUP BY with no pseudo items at all still aggregates correctly", %{
      conn: conn
    } do
      query = %Query{
        source: ["library", "fiction", "book"],
        select: [{:computed, "total", {:call, "count", [{:field, ["title"]}]}}]
      }

      assert {:ok, [%{"total" => 2}]} = materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "%Scry.Core.CombinedQuery{} and a WITH-bound source" do
    test "CombinedQuery delegates to Scry.Core.QueryOps.run_document/4", %{conn: conn} do
      left = %Query{source: ["library", "fiction"], select: [{:field, ["name"]}]}
      right = %Query{source: ["library", "nonfiction"], select: [{:field, ["name"]}]}
      combined = %CombinedQuery{op: :union, left: left, right: right}

      assert {:ok, rows} = materialize(Engine.execute(conn, combined, %{}))
      assert rows |> Enum.map(& &1["name"]) |> Enum.sort() == ["Fiction", "Non-Fiction"]
    end

    test "a WITH-bound top-level source runs the binding instead of a real collection", %{
      conn: conn
    } do
      binding = %Query{source: ["library"], select: [{:field, ["name"]}]}

      query = %Query{
        source: ["main_only"],
        with_bindings: %{"main_only" => binding},
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Main"]
    end
  end

  describe "describe_source/2" do
    test "reports every observed field on the given collection", %{conn: conn} do
      assert {:ok, fields} = Engine.describe_source(conn, "library__fiction__book")
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["title"].scalar == :string
      assert by_name["year"].scalar == :integer
      assert by_name["title"].nullable == true
    end

    test "a collection that was never created is not found", %{conn: conn} do
      assert {:error, :not_found} = Engine.describe_source(conn, "no_such_collection")
    end
  end
end
