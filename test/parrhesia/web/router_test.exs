defmodule Parrhesia.Web.RouterTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  import Plug.Conn
  import Plug.Test

  alias Parrhesia.API.Sync
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Telemetry
  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.Router

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

  test "GET /metrics includes exported relay counters and gauges" do
    Telemetry.emit(
      [:parrhesia, :ingest, :result],
      %{count: 1},
      %{traffic_class: :generic, outcome: :accepted, reason: :accepted}
    )

    Telemetry.emit(
      [:parrhesia, :listener, :population],
      %{connections: 2, subscriptions: 3},
      %{listener_id: :public}
    )

    Telemetry.emit(
      [:parrhesia, :rate_limit, :hit],
      %{count: 1},
      %{scope: :event_ingest_per_ip, traffic_class: :generic}
    )

    Telemetry.emit_vm_memory()
    _ = Repo.query!("SELECT 1")

    conn =
      conn(:get, "/metrics")
      |> route_conn(
        listener(%{
          features: %{metrics: %{enabled: true, access: %{private_networks_only: true}}}
        })
      )

    assert conn.status == 200
    assert String.contains?(conn.resp_body, "parrhesia_ingest_events_count")
    assert String.contains?(conn.resp_body, "parrhesia_listener_connections_active")
    assert String.contains?(conn.resp_body, "listener_id=\"public\"")
    assert String.contains?(conn.resp_body, "parrhesia_rate_limit_hits_count")
    assert String.contains?(conn.resp_body, "scope=\"event_ingest_per_ip\"")
    assert String.contains?(conn.resp_body, "parrhesia_db_query_count")
    assert String.contains?(conn.resp_body, "repo_role=\"write\"")
    assert String.contains?(conn.resp_body, "parrhesia_vm_memory_binary_bytes")
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

  test "GET /relay accepts proxy-asserted TLS identity from trusted proxies" do
    test_listener =
      listener(%{
        transport: %{
          scheme: :http,
          tls: %{
            mode: :proxy_terminated,
            proxy_headers: %{enabled: true, required: true}
          }
        },
        proxy: %{trusted_cidrs: ["10.0.0.0/8"], honor_x_forwarded_for: true}
      })

    conn =
      conn(:get, "/relay")
      |> put_req_header("accept", "application/nostr+json")
      |> put_req_header("x-parrhesia-client-cert-verified", "true")
      |> put_req_header("x-parrhesia-client-spki-sha256", "proxy-spki-pin")
      |> Plug.Test.put_peer_data(%{
        address: {10, 1, 2, 3},
        port: 443,
        ssl_cert: nil
      })
      |> route_conn(test_listener)

    assert conn.status == 200
  end

  test "GET /relay rejects missing proxy-asserted TLS identity when required" do
    test_listener =
      listener(%{
        transport: %{
          scheme: :http,
          tls: %{
            mode: :proxy_terminated,
            proxy_headers: %{enabled: true, required: true}
          }
        },
        proxy: %{trusted_cidrs: ["10.0.0.0/8"], honor_x_forwarded_for: true}
      })

    conn =
      conn(:get, "/relay")
      |> put_req_header("accept", "application/nostr+json")
      |> Plug.Test.put_peer_data(%{
        address: {10, 1, 2, 3},
        port: 443,
        ssl_cert: nil
      })
      |> route_conn(test_listener)

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "GET /relay rejects proxy-asserted TLS identity when the pin mismatches" do
    test_listener =
      listener(%{
        transport: %{
          scheme: :http,
          tls: %{
            mode: :proxy_terminated,
            client_pins: [%{type: :spki_sha256, value: "expected-spki-pin"}],
            proxy_headers: %{enabled: true, required: true}
          }
        },
        proxy: %{trusted_cidrs: ["10.0.0.0/8"], honor_x_forwarded_for: true}
      })

    conn =
      conn(:get, "/relay")
      |> put_req_header("accept", "application/nostr+json")
      |> put_req_header("x-parrhesia-client-cert-verified", "true")
      |> put_req_header("x-parrhesia-client-spki-sha256", "wrong-spki-pin")
      |> Plug.Test.put_peer_data(%{
        address: {10, 1, 2, 3},
        port: 443,
        ssl_cert: nil
      })
      |> route_conn(test_listener)

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
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

    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
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
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
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
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
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
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
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

  test "POST /management stats and health include sync summary" do
    management_url = "http://www.example.com/management"
    initial_total = Sync.sync_stats() |> elem(1) |> Map.fetch!("servers_total")
    server_id = "router-sync-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, _server} =
             Sync.put_server(%{
               "id" => server_id,
               "url" => "wss://relay-a.example/relay",
               "enabled?" => false,
               "auth_pubkey" => String.duplicate("a", 64),
               "filters" => [%{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}],
               "tls" => %{
                 "pins" => [
                   %{
                     "type" => "spki_sha256",
                     "value" => "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                   }
                 ]
               }
             })

    on_exit(fn ->
      _ = Sync.remove_server(server_id)
    end)

    stats_conn =
      conn(
        :post,
        "/management",
        JSON.encode!(%{
          "method" => "stats",
          "params" => %{}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
      |> Router.call([])

    assert stats_conn.status == 200

    assert %{
             "ok" => true,
             "result" => %{
               "sync" => %{"servers_total" => servers_total}
             }
           } = JSON.decode!(stats_conn.resp_body)

    assert servers_total == initial_total + 1

    health_conn =
      conn(
        :post,
        "/management",
        JSON.encode!(%{
          "method" => "health",
          "params" => %{}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", nip98_authorization("POST", management_url))
      |> Router.call([])

    assert health_conn.status == 200

    assert %{
             "ok" => true,
             "result" => %{
               "status" => status,
               "sync" => %{"servers_total" => ^servers_total}
             }
           } = JSON.decode!(health_conn.resp_body)

    assert status in ["ok", "degraded"]
  end

  test "POST /management returns not found when admin feature is disabled on the listener" do
    conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> route_conn(listener(%{features: %{admin: %{enabled: false}}}))

    assert conn.status == 404
  end

  test "POST /management rejects replayed NIP-98 headers" do
    management_url = "http://www.example.com/management"
    authorization = nip98_authorization("POST", management_url)

    first_conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert first_conn.status == 200

    second_conn =
      conn(:post, "/management", JSON.encode!(%{"method" => "ping", "params" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)
      |> Router.call([])

    assert second_conn.status == 401

    assert JSON.decode!(second_conn.resp_body) == %{
             "ok" => false,
             "error" => "replayed-auth-event"
           }
  end

  defp nip98_event(method, url) do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("a", 64),
      "created_at" => now,
      "kind" => 27_235,
      "tags" => [["method", method], ["u", url]],
      "content" => "token-#{System.unique_integer([:positive, :monotonic])}",
      "sig" => String.duplicate("b", 128)
    }

    Map.put(base, "id", EventValidator.compute_id(base))
  end

  defp nip98_authorization(method, url) do
    "Nostr " <> Base.encode64(JSON.encode!(nip98_event(method, url)))
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
