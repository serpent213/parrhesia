defmodule Parrhesia.Web.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Web.Router

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "GET /health returns ok" do
    conn = conn(:get, "/health") |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /ready returns ready" do
    conn = conn(:get, "/ready") |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body == "ready"
  end

  test "GET /relay with nostr accept header returns NIP-11 document" do
    conn =
      conn(:get, "/relay")
      |> put_req_header("accept", "application/nostr+json")
      |> Router.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/nostr+json; charset=utf-8"]

    body = JSON.decode!(conn.resp_body)

    assert body["name"] == "Parrhesia"
    assert 11 in body["supported_nips"]
  end

  test "GET /metrics returns prometheus payload for private-network clients" do
    conn = conn(:get, "/metrics") |> Router.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "GET /metrics denies public-network clients by default" do
    conn = conn(:get, "/metrics")
    conn = %{conn | remote_ip: {8, 8, 8, 8}}
    conn = Router.call(conn, [])

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "GET /metrics can be disabled on the main endpoint" do
    previous_metrics = Application.get_env(:parrhesia, :metrics, [])

    Application.put_env(
      :parrhesia,
      :metrics,
      Keyword.put(previous_metrics, :enabled_on_main_endpoint, false)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :metrics, previous_metrics)
    end)

    conn = conn(:get, "/metrics") |> Router.call([])

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "GET /metrics accepts bearer auth when configured" do
    previous_metrics = Application.get_env(:parrhesia, :metrics, [])

    Application.put_env(
      :parrhesia,
      :metrics,
      previous_metrics
      |> Keyword.put(:private_networks_only, false)
      |> Keyword.put(:auth_token, "secret-token")
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :metrics, previous_metrics)
    end)

    denied_conn = conn(:get, "/metrics") |> Router.call([])

    assert denied_conn.status == 403

    allowed_conn =
      conn(:get, "/metrics")
      |> put_req_header("authorization", "Bearer secret-token")
      |> Router.call([])

    assert allowed_conn.status == 200
  end

  test "POST /management requires authorization" do
    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 401
    assert JSON.decode!(conn.resp_body) == %{"ok" => false, "error" => "auth-required"}
  end

  test "POST /management accepts valid NIP-98 header" do
    management_url = "http://www.example.com/management"
    auth_event = nip98_event("POST", management_url)

    authorization = "Nostr " <> Base.encode64(JSON.encode!(auth_event))

    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert conn.status == 200

    assert JSON.decode!(conn.resp_body) == %{
             "ok" => true,
             "result" => %{"status" => "ok"}
           }
  end

  defp nip98_event(method, url) do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("a", 64),
      "created_at" => now,
      "kind" => 27_235,
      "tags" => [["method", method], ["u", url]],
      "content" => "",
      "sig" => String.duplicate("b", 128)
    }

    Map.put(base, "id", EventValidator.compute_id(base))
  end
end
