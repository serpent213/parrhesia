defmodule Parrhesia.Web.TLSE2ETest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Repo
  alias Parrhesia.Sync.Transport.WebSockexClient
  alias Parrhesia.TestSupport.TLSCerts
  alias Parrhesia.Web.Endpoint

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_tls_e2e_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
      _ = File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "HTTPS listener serves NIP-11 and reloads certificate files from disk", %{tmp_dir: tmp_dir} do
    ca = TLSCerts.create_ca!(tmp_dir, "reload")
    server_a = TLSCerts.issue_server_cert!(tmp_dir, ca, "reload-server-a")
    server_b = TLSCerts.issue_server_cert!(tmp_dir, ca, "reload-server-b")

    active_certfile = Path.join(tmp_dir, "active-server.cert.pem")
    active_keyfile = Path.join(tmp_dir, "active-server.key.pem")
    File.cp!(server_a.certfile, active_certfile)
    File.cp!(server_a.keyfile, active_keyfile)

    port = free_port()
    endpoint_name = unique_name("TLSEndpointReload")
    listener_id = :reload_tls

    start_supervised!(
      {Endpoint,
       name: endpoint_name,
       listeners: %{
         listener_id =>
           listener(listener_id, port, %{
             transport: %{
               scheme: :https,
               tls: %{
                 mode: :server,
                 certfile: active_certfile,
                 keyfile: active_keyfile,
                 cipher_suite: :compatible
               }
             }
           })
       }}
    )

    assert_eventually(
      fn ->
        case nip11_request(port, ca.certfile) do
          {:ok, 200} -> true
          _other -> false
        end
      end,
      5_000
    )

    expected_first_fingerprint = TLSCerts.cert_sha256!(server_a.certfile)

    assert_eventually(
      fn ->
        server_cert_fingerprint(port) == {:ok, expected_first_fingerprint}
      end,
      5_000
    )

    File.cp!(server_b.certfile, active_certfile)
    File.cp!(server_b.keyfile, active_keyfile)

    assert :ok = Endpoint.reload_listener(endpoint_name, listener_id)

    expected_reloaded_fingerprint = TLSCerts.cert_sha256!(server_b.certfile)

    assert_eventually(
      fn ->
        server_cert_fingerprint(port) == {:ok, expected_reloaded_fingerprint}
      end,
      10_000
    )
  end

  test "mutual TLS requires a client certificate and enforces optional client pins", %{
    tmp_dir: tmp_dir
  } do
    ca = TLSCerts.create_ca!(tmp_dir, "mutual")
    server = TLSCerts.issue_server_cert!(tmp_dir, ca, "mutual-server")
    allowed_client = TLSCerts.issue_client_cert!(tmp_dir, ca, "allowed-client")
    other_client = TLSCerts.issue_client_cert!(tmp_dir, ca, "other-client")
    allowed_pin = TLSCerts.spki_pin!(allowed_client.certfile)

    port = free_port()

    start_supervised!(
      {Endpoint,
       name: unique_name("TLSEndpointMutual"),
       listeners: %{
         mutual_tls:
           listener(:mutual_tls, port, %{
             transport: %{
               scheme: :https,
               tls: %{
                 mode: :mutual,
                 certfile: server.certfile,
                 keyfile: server.keyfile,
                 cacertfile: ca.certfile,
                 client_pins: [%{type: :spki_sha256, value: allowed_pin}]
               }
             }
           })
       }}
    )

    assert {:error, _reason} = nip11_request(port, ca.certfile)

    assert {:ok, 403} =
             nip11_request(
               port,
               ca.certfile,
               certfile: other_client.certfile,
               keyfile: other_client.keyfile
             )

    assert {:ok, 200} =
             nip11_request(
               port,
               ca.certfile,
               certfile: allowed_client.certfile,
               keyfile: allowed_client.keyfile
             )
  end

  test "WSS relay accepts a pinned server certificate", %{tmp_dir: tmp_dir} do
    ca = TLSCerts.create_ca!(tmp_dir, "wss")
    server = TLSCerts.issue_server_cert!(tmp_dir, ca, "wss-server")
    server_pin = TLSCerts.spki_pin!(server.certfile)
    port = free_port()

    start_supervised!(
      {Endpoint,
       name: unique_name("TLSEndpointWSS"),
       listeners: %{
         wss_tls:
           listener(:wss_tls, port, %{
             transport: %{
               scheme: :https,
               tls: %{
                 mode: :server,
                 certfile: server.certfile,
                 keyfile: server.keyfile
               }
             }
           })
       }}
    )

    server_config = %{
      url: "wss://localhost:#{port}/relay",
      tls: %{
        mode: :required,
        hostname: "localhost",
        pins: [%{type: :spki_sha256, value: server_pin}]
      }
    }

    assert {:ok, websocket} =
             WebSockexClient.connect(
               self(),
               server_config,
               websocket_opts: [ssl_options: websocket_ssl_options(ca.certfile)]
             )

    assert_receive {:sync_transport, ^websocket, :connected, _metadata}, 5_000

    assert :ok = WebSockexClient.send_json(websocket, ["COUNT", "tls-sub", %{"kinds" => [1]}])

    assert_receive {:sync_transport, ^websocket, :frame, ["COUNT", "tls-sub", payload]}, 5_000
    assert is_map(payload)
    assert Map.has_key?(payload, "count")
  end

  test "WSS relay rejects a mismatched pinned server certificate", %{tmp_dir: tmp_dir} do
    ca = TLSCerts.create_ca!(tmp_dir, "wss-mismatch")
    server = TLSCerts.issue_server_cert!(tmp_dir, ca, "wss-mismatch-server")
    wrong_server = TLSCerts.issue_server_cert!(tmp_dir, ca, "wss-mismatch-other")
    wrong_pin = TLSCerts.spki_pin!(wrong_server.certfile)
    port = free_port()

    start_supervised!(
      {Endpoint,
       name: unique_name("TLSEndpointWSSMismatch"),
       listeners: %{
         wss_tls_mismatch:
           listener(:wss_tls_mismatch, port, %{
             transport: %{
               scheme: :https,
               tls: %{
                 mode: :server,
                 certfile: server.certfile,
                 keyfile: server.keyfile
               }
             }
           })
       }}
    )

    server_config = %{
      url: "wss://localhost:#{port}/relay",
      tls: %{
        mode: :required,
        hostname: "localhost",
        pins: [%{type: :spki_sha256, value: wrong_pin}]
      }
    }

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, {:handshake_failure, _reason}}}} =
             WebSockexClient.connect(
               self(),
               server_config,
               websocket_opts: [ssl_options: websocket_ssl_options(ca.certfile)]
             )
  end

  defp listener(id, port, overrides) do
    deep_merge(
      %{
        id: id,
        enabled: true,
        bind: %{ip: {127, 0, 0, 1}, port: port},
        transport: %{scheme: :http, tls: %{mode: :disabled}},
        proxy: %{trusted_cidrs: [], honor_x_forwarded_for: true},
        network: %{allow_all: true},
        features: %{
          nostr: %{enabled: true},
          admin: %{enabled: true},
          metrics: %{enabled: false, access: %{allow_all: true}, auth_token: nil}
        },
        auth: %{nip42_required: false, nip98_required_for_admin: true},
        baseline_acl: %{read: [], write: []},
        bandit_options: []
      },
      overrides
    )
  end

  defp nip11_request(port, cacertfile, opts \\ []) do
    transport_opts =
      [
        mode: :binary,
        verify: :verify_peer,
        cacertfile: String.to_charlist(cacertfile),
        server_name_indication: ~c"localhost",
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
      |> maybe_put_file_opt(:certfile, Keyword.get(opts, :certfile))
      |> maybe_put_file_opt(:keyfile, Keyword.get(opts, :keyfile))

    case Req.get(
           url: "https://localhost:#{port}/relay",
           headers: [{"accept", "application/nostr+json"}],
           decode_body: false,
           connect_options: [transport_opts: transport_opts]
         ) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp server_cert_fingerprint(port) do
    case :ssl.connect(
           ~c"127.0.0.1",
           port,
           [
             verify: :verify_none,
             active: false,
             reuse_sessions: false,
             server_name_indication: ~c"localhost"
           ],
           5_000
         ) do
      {:ok, socket} ->
        try do
          case :ssl.peercert(socket) do
            {:ok, cert_der} -> {:ok, Base.encode64(:crypto.hash(:sha256, cert_der))}
            {:error, _reason} = error -> error
          end
        after
          :ok = :ssl.close(socket)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp ca_certs(certfile) do
    certfile
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.map(&elem(&1, 1))
  end

  defp maybe_put_file_opt(options, _key, nil), do: options

  defp maybe_put_file_opt(options, key, value) do
    Keyword.put(options, key, String.to_charlist(value))
  end

  defp websocket_ssl_options(cacertfile) do
    [
      cacerts: ca_certs(cacertfile),
      server_name_indication: ~c"localhost",
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
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

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp assert_eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, timeout_ms, 50)
  end

  defp do_assert_eventually(fun, deadline, timeout_ms, interval_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met in time (#{timeout_ms} ms)")

      true ->
        receive do
        after
          interval_ms -> do_assert_eventually(fun, deadline, timeout_ms, interval_ms)
        end
    end
  end
end
