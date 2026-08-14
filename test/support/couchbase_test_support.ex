defmodule Scry.Engine.Couchbase.TestSupport do
  @moduledoc """
  Shared bucket/scope provisioning for this package's own real-backend
  test suites (`Scry.Engine.CouchbaseTest`/`Scry.Engine.Couchbase.
  ParityTest`/`Scry.Engine.Couchbase.RelDocTest`) -- not part of the
  package itself, `test/support` only (`mix.exs`'s own `elixirc_paths`
  entry for `:test`).

  **A real, confirmed async-provisioning finding**: creating a bucket
  returns a real `202 Accepted` immediately, but the bucket genuinely
  isn't usable yet -- confirmed directly, a scope-creation call issued
  right after a `202` response reliably 404s for a few hundred
  milliseconds to a few seconds while the cluster actually allocates
  it. `reset_bucket!/2` polls scope creation itself (real work, not a
  fixed guessed sleep) until it succeeds, the same "confirm a real
  server state transition rather than assume a fixed delay is long
  enough" posture `scry_engine_arangodb`'s own async-database-creation
  handling already established.
  """

  @mgmt_base_url "http://localhost:8091"
  @scope "scry"

  @doc "Drops `bucket` if it exists, recreates it fresh, then creates the fixed `\"scry\"` scope every test suite in this package reads/writes -- unconditional, not idempotent-tolerant, the same clean-slate-per-run posture `scry_engine_arangodb`'s own parity test already established."
  @spec reset_bucket!(String.t(), {String.t(), String.t()}) :: :ok
  def reset_bucket!(bucket, auth) do
    delete_bucket(bucket, auth)
    create_bucket!(bucket, auth)
    wait_until_scope_creatable!(bucket, auth)
    :ok
  end

  defp delete_bucket(bucket, auth) do
    Req.delete(@mgmt_base_url <> "/pools/default/buckets/#{bucket}", auth: {:basic, basic(auth)})
  end

  defp create_bucket!(bucket, auth) do
    case Req.post(@mgmt_base_url <> "/pools/default/buckets",
           auth: {:basic, basic(auth)},
           form: [name: bucket, bucketType: "couchbase", ramQuotaMB: "100", flushEnabled: "1"]
         ) do
      {:ok, %Req.Response{status: 202}} ->
        :ok

      {:ok, %Req.Response{status: 400, body: %{"errors" => %{"name" => msg}}}} ->
        if String.contains?(to_string(msg), "already exists"),
          do: :ok,
          else: raise("Couchbase bucket #{bucket} create failed: #{inspect(msg)}")

      {:ok, %Req.Response{status: status, body: body}} ->
        raise("Couchbase bucket #{bucket} create failed (#{status}): #{inspect(body)}")
    end
  end

  defp wait_until_scope_creatable!(bucket, auth, attempts \\ 50)

  defp wait_until_scope_creatable!(_bucket, _auth, 0),
    do: raise("Couchbase bucket #{@scope} scope never became creatable")

  defp wait_until_scope_creatable!(bucket, auth, attempts) do
    case Req.post(@mgmt_base_url <> "/pools/default/buckets/#{bucket}/scopes",
           auth: {:basic, basic(auth)},
           form: [name: @scope]
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      _not_ready ->
        Process.sleep(200)
        wait_until_scope_creatable!(bucket, auth, attempts - 1)
    end
  end

  defp basic({username, password}), do: username <> ":" <> password
end
