defmodule Parrhesia.Web.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Web.Listener
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
    conn =
      conn(:get, "/metrics")
      |> route_conn(
        listener(%{
          features: %{metrics: %{enabled: true, access: %{private_networks_only: true}}}
        })
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "GET /metrics denies public-network clients by default" do
    conn = conn(:get, "/metrics")
    conn = %{conn | remote_ip: {8, 8, 8, 8}}

    test_listener =
      listener(%{features: %{metrics: %{enabled: true, access: %{private_networks_only: true}}}})

    conn = Listener.put_conn(conn, listener: test_listener)

    refute Listener.metrics_allowed?(Listener.from_conn(conn), conn)

    conn = Router.call(conn, [])

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "GET /metrics can be disabled on the main endpoint" do
    conn =
      conn(:get, "/metrics")
      |> route_conn(listener(%{features: %{metrics: %{enabled: false}}}))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "GET /metrics accepts bearer auth when configured" do
    test_listener =
      listener(%{
        features: %{
          metrics: %{
            enabled: true,
            access: %{private_networks_only: false},
            auth_token: "secret-token"
          }
        }
      })

    denied_conn = conn(:get, "/metrics") |> route_conn(test_listener)

    assert denied_conn.status == 403

    allowed_conn =
      conn(:get, "/metrics")
      |> put_req_header("authorization", "Bearer secret-token")
      |> route_conn(test_listener)

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

  test "POST /management denies blocked IPs before auth" do
    assert :ok = Parrhesia.Storage.moderation().block_ip(%{}, "8.8.8.8")

    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, {8, 8, 8, 8})
      |> Router.call([])

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "GET /relay denies blocked IPs" do
    assert :ok = Parrhesia.Storage.moderation().block_ip(%{}, "8.8.4.4")

    conn =
      conn(:get, "/relay")
      |> put_req_header("accept", "application/nostr+json")
      |> Map.put(:remote_ip, {8, 8, 4, 4})
      |> Router.call([])

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "POST /management supports ACL methods" do
    management_url = "http://www.example.com/management"
    auth_event = nip98_event("POST", management_url)
    authorization = "Nostr " <> Base.encode64(JSON.encode!(auth_event))

    grant_conn =
      conn(
        :post,
        "/management",
        JSON.encode!(%{
          "method" => "acl_grant",
          "params" => %{
            "principal_type" => "pubkey",
            "principal" => String.duplicate("c", 64),
            "capability" => "sync_read",
            "match" => %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
          }
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert grant_conn.status == 200

    list_conn =
      conn(
        :post,
        "/management",
        JSON.encode!(%{
          "method" => "acl_list",
          "params" => %{"principal" => String.duplicate("c", 64)}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert list_conn.status == 200

    assert %{
             "ok" => true,
             "result" => %{
               "rules" => [
                 %{
                   "principal" => principal,
                   "capability" => "sync_read"
                 }
               ]
             }
           } = JSON.decode!(list_conn.resp_body)

    assert principal == String.duplicate("c", 64)
  end

  test "POST /management supports identity methods" do
    management_url = "http://www.example.com/management"
    auth_event = nip98_event("POST", management_url)
    authorization = "Nostr " <> Base.encode64(JSON.encode!(auth_event))

    conn =
      conn(
        :post,
        "/management",
        JSON.encode!(%{
          "method" => "identity_ensure",
          "params" => %{}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert conn.status == 200

    assert %{
             "ok" => true,
             "result" => %{
               "pubkey" => pubkey
             }
           } = JSON.decode!(conn.resp_body)

    assert is_binary(pubkey)
    assert byte_size(pubkey) == 64
  end

  test "POST /management returns not found when admin feature is disabled on the listener" do
    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> route_conn(listener(%{features: %{admin: %{enabled: false}}}))

    assert conn.status == 404
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

  defp listener(overrides) do
    deep_merge(
      %{
        id: :test,
        enabled: true,
        bind: %{ip: {127, 0, 0, 1}, port: 4413},
        transport: %{scheme: :http, tls: %{mode: :disabled}},
        proxy: %{trusted_cidrs: [], honor_x_forwarded_for: true},
        network: %{allow_all: true},
        features: %{
          nostr: %{enabled: true},
          admin: %{enabled: true},
          metrics: %{enabled: true, access: %{private_networks_only: true}, auth_token: nil}
        },
        auth: %{nip42_required: false, nip98_required_for_admin: true},
        baseline_acl: %{read: [], write: []}
      },
      overrides
    )
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp route_conn(conn, listener) do
    conn
    |> Listener.put_conn(listener: listener)
    |> Router.call([])
  end
end
