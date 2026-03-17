defmodule NodeSyncE2E.RelayClient do
  use WebSockex

  def start_link(url, owner, opts \\ []) do
    WebSockex.start_link(
      url,
      __MODULE__,
      owner,
      Keyword.put(opts, :handle_initial_conn_failure, true)
    )
  end

  def send_json(pid, payload) do
    WebSockex.cast(pid, {:send_json, payload})
  end

  def close(pid) do
    WebSockex.cast(pid, :close)
  end

  @impl true
  def handle_connect(_conn, owner) do
    send(owner, {:node_sync_e2e_relay_client, self(), :connected})
    {:ok, owner}
  end

  @impl true
  def handle_frame({:text, payload}, owner) do
    frame =
      case JSON.decode(payload) do
        {:ok, decoded} -> decoded
        {:error, reason} -> {:decode_error, reason, payload}
      end

    send(owner, {:node_sync_e2e_relay_client, self(), :frame, frame})
    {:ok, owner}
  end

  def handle_frame(frame, owner) do
    send(owner, {:node_sync_e2e_relay_client, self(), :frame, frame})
    {:ok, owner}
  end

  @impl true
  def handle_cast({:send_json, payload}, owner) do
    {:reply, {:text, JSON.encode!(payload)}, owner}
  end

  def handle_cast(:close, owner) do
    {:close, owner}
  end

  @impl true
  def handle_disconnect(status, owner) do
    send(owner, {:node_sync_e2e_relay_client, self(), :disconnected, status})
    {:ok, owner}
  end
end

defmodule NodeSyncE2E.Runner do
  alias NodeSyncE2E.RelayClient
  alias Parrhesia.API.Auth

  @kind 5000
  @subsystem_tag "node-sync-e2e"
  @default_resource "tribes.accounts.user"
  @default_server_id "node-a-upstream"
  @default_admin_private_key String.duplicate("1", 64)
  @default_client_private_key String.duplicate("2", 64)
  @frame_timeout_ms 5_000

  def main(argv) do
    with {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, _apps} <- Application.ensure_all_started(:websockex),
         {:ok, command, opts} <- parse_args(argv),
         {:ok, config} <- load_config(),
         :ok <- dispatch(command, config, opts) do
      IO.puts("node-sync-e2e #{command} completed")
    else
      {:error, reason} ->
        IO.puts(:stderr, "node-sync-e2e failed: #{format_reason(reason)}")
        System.halt(1)
    end
  end

  defp parse_args(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [state_file: :string])

    cond do
      invalid != [] ->
        {:error, {:invalid_arguments, invalid}}

      length(rest) != 1 ->
        {:error, :missing_command}

      true ->
        {:ok, hd(rest), opts}
    end
  end

  defp dispatch("bootstrap", config, opts) do
    with {:ok, state_file} <- fetch_state_file(opts),
         :ok <- ensure_nodes_ready(config),
         {:ok, node_a_pubkey} <- fetch_node_pubkey(config, config.node_a),
         {:ok, node_b_pubkey} <- fetch_node_pubkey(config, config.node_b),
         :ok <- ensure_identity_matches(config.node_a, node_a_pubkey, :node_a),
         :ok <- ensure_identity_matches(config.node_b, node_b_pubkey, :node_b),
         :ok <- ensure_acl(config, config.node_a, node_b_pubkey, "sync_read", config.filter),
         :ok <-
           ensure_acl(config, config.node_a, config.client_pubkey, "sync_write", config.filter),
         :ok <- ensure_acl(config, config.node_b, node_a_pubkey, "sync_write", config.filter),
         :ok <-
           ensure_acl(config, config.node_b, config.client_pubkey, "sync_read", config.filter),
         {:ok, catchup_event} <- publish_phase_event(config, config.node_a, "catchup"),
         :ok <- configure_sync(config, node_a_pubkey),
         :ok <- wait_for_sync_connected(config, config.node_b, config.server_id),
         :ok <- wait_for_event(config, config.node_b, catchup_event["id"]),
         {:ok, live_event} <- publish_phase_event(config, config.node_a, "live"),
         :ok <- wait_for_event(config, config.node_b, live_event["id"]),
         {:ok, stats} <- fetch_sync_server_stats(config, config.node_b, config.server_id),
         :ok <- ensure_minimum_counter(stats, "events_accepted", 2),
         :ok <-
           save_state(state_file, %{
             "run_id" => config.run_id,
             "resource" => config.resource,
             "server_id" => config.server_id,
             "node_a_pubkey" => node_a_pubkey,
             "node_b_pubkey" => node_b_pubkey,
             "catchup_event_id" => catchup_event["id"],
             "live_event_id" => live_event["id"]
           }) do
      :ok
    end
  end

  defp dispatch("publish-resume", config, opts) do
    with {:ok, state_file} <- fetch_state_file(opts),
         :ok <- ensure_run_matches(config, load_state(state_file)),
         {:ok, resume_event} <- publish_phase_event(config, config.node_a, "resume"),
         :ok <-
           save_state(state_file, %{
             "run_id" => config.run_id,
             "resource" => config.resource,
             "server_id" => config.server_id,
             "resume_event_id" => resume_event["id"]
           }) do
      :ok
    end
  end

  defp dispatch("verify-resume", config, opts) do
    with {:ok, state_file} <- fetch_state_file(opts),
         state = load_state(state_file),
         :ok <- ensure_run_matches(config, state),
         {:ok, resume_event_id} <- fetch_state_value(state, "resume_event_id"),
         :ok <- ensure_nodes_ready(config),
         :ok <- wait_for_sync_connected(config, config.node_b, config.server_id),
         :ok <- wait_for_event(config, config.node_b, resume_event_id),
         {:ok, stats} <- fetch_sync_server_stats(config, config.node_b, config.server_id),
         :ok <- ensure_minimum_counter(stats, "events_accepted", 3),
         :ok <- ensure_minimum_counter(stats, "query_runs", 2) do
      :ok
    end
  end

  defp dispatch(other, _config, _opts), do: {:error, {:unknown_command, other}}

  defp fetch_state_file(opts) do
    case Keyword.get(opts, :state_file) do
      nil -> {:error, :missing_state_file}
      path -> {:ok, path}
    end
  end

  defp load_config do
    resource = System.get_env("PARRHESIA_NODE_SYNC_E2E_RESOURCE", @default_resource)

    admin_private_key =
      System.get_env("PARRHESIA_NODE_SYNC_E2E_ADMIN_PRIVATE_KEY", @default_admin_private_key)

    client_private_key =
      System.get_env("PARRHESIA_NODE_SYNC_E2E_CLIENT_PRIVATE_KEY", @default_client_private_key)

    with {:ok, node_a} <- load_node("A"),
         {:ok, node_b} <- load_node("B"),
         {:ok, client_pubkey} <- derive_pubkey(client_private_key) do
      {:ok,
       %{
         run_id: System.get_env("PARRHESIA_NODE_SYNC_E2E_RUN_ID", default_run_id()),
         resource: resource,
         filter: %{"kinds" => [@kind], "#r" => [resource]},
         admin_private_key: admin_private_key,
         client_private_key: client_private_key,
         client_pubkey: client_pubkey,
         server_id: System.get_env("PARRHESIA_NODE_SYNC_E2E_SERVER_ID", @default_server_id),
         node_a: node_a,
         node_b: node_b
       }}
    end
  end

  defp load_node(suffix) do
    http_url =
      System.get_env("PARRHESIA_NODE_#{suffix}_HTTP_URL") ||
        System.get_env("PARRHESIA_NODE_#{suffix}_MANAGEMENT_BASE_URL")

    websocket_url = System.get_env("PARRHESIA_NODE_#{suffix}_WS_URL")
    relay_auth_url = System.get_env("PARRHESIA_NODE_#{suffix}_RELAY_AUTH_URL", websocket_url)
    sync_url = System.get_env("PARRHESIA_NODE_#{suffix}_SYNC_URL", relay_auth_url)

    cond do
      is_nil(http_url) or http_url == "" ->
        {:error, {:missing_env, "PARRHESIA_NODE_#{suffix}_HTTP_URL"}}

      is_nil(websocket_url) or websocket_url == "" ->
        {:error, {:missing_env, "PARRHESIA_NODE_#{suffix}_WS_URL"}}

      true ->
        {:ok,
         %{
           http_url: http_url,
           websocket_url: websocket_url,
           relay_auth_url: relay_auth_url,
           sync_url: sync_url
         }}
    end
  end

  defp ensure_nodes_ready(config) do
    with :ok <- wait_for_health(config.node_a),
         :ok <- wait_for_health(config.node_b) do
      :ok
    end
  end

  defp wait_for_health(node) do
    case wait_until("node health #{node.http_url}", 15_000, 250, fn ->
           health_url = node.http_url <> "/health"

           case Req.get(
                  url: health_url,
                  decode_body: false,
                  connect_options: [timeout: 1_000],
                  receive_timeout: 1_000
                ) do
             {:ok, %{status: 200, body: "ok"}} -> {:ok, :ready}
             {:ok, %{status: status}} -> {:retry, {:unexpected_status, status}}
             {:error, reason} -> {:retry, reason}
           end
         end) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_node_pubkey(config, node) do
    case management_call(config, node, "identity_get", %{}) do
      {:ok, %{"pubkey" => pubkey}} when is_binary(pubkey) -> {:ok, String.downcase(pubkey)}
      {:ok, other} -> {:error, {:unexpected_identity_payload, other}}
      {:error, reason} -> {:error, {:identity_get_failed, reason}}
    end
  end

  defp ensure_identity_matches(node, expected_pubkey, label) do
    if fetch_nip11_pubkey(node) == expected_pubkey do
      :ok
    else
      {:error, {label, :identity_mismatch}}
    end
  end

  defp fetch_nip11_pubkey(node) do
    relay_url = node.http_url <> "/relay"

    case Req.get(
           url: relay_url,
           headers: [{"accept", "application/nostr+json"}],
           decode_body: false,
           connect_options: [timeout: 1_000],
           receive_timeout: 1_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{"pubkey" => pubkey}} when is_binary(pubkey) -> String.downcase(pubkey)
          {:ok, other} -> raise "unexpected relay info payload: #{inspect(other)}"
          {:error, reason} -> raise "relay info JSON decode failed: #{inspect(reason)}"
        end

      {:ok, %{status: status}} ->
        raise "relay info request failed with status #{status}"

      {:error, reason} ->
        raise "relay info request failed: #{inspect(reason)}"
    end
  end

  defp ensure_acl(config, node, principal, capability, match) do
    params = %{
      "principal_type" => "pubkey",
      "principal" => principal,
      "capability" => capability,
      "match" => match
    }

    case management_call(config, node, "acl_grant", params) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, other} -> {:error, {:unexpected_acl_result, other}}
      {:error, reason} -> {:error, {:acl_grant_failed, capability, principal, reason}}
    end
  end

  defp configure_sync(config, node_a_pubkey) do
    params = %{
      "id" => config.server_id,
      "url" => config.node_a.sync_url,
      "enabled?" => true,
      "auth_pubkey" => node_a_pubkey,
      "filters" => [config.filter],
      "tls" => sync_tls_config(config.node_a.sync_url)
    }

    with {:ok, _server} <- management_call(config, config.node_b, "sync_put_server", params),
         {:ok, %{"ok" => true}} <-
           management_call(config, config.node_b, "sync_start_server", %{"id" => config.server_id}) do
      :ok
    end
  end

  defp sync_tls_config("wss://" <> _rest) do
    raise "wss sync URLs are not supported by this harness without explicit pin configuration"
  end

  defp sync_tls_config(_url) do
    %{"mode" => "disabled", "pins" => []}
  end

  defp publish_phase_event(config, node, phase) do
    event =
      %{
        "created_at" => System.system_time(:second),
        "kind" => @kind,
        "tags" => [
          ["r", config.resource],
          ["t", @subsystem_tag],
          ["run", config.run_id],
          ["phase", phase]
        ],
        "content" => "#{phase}:#{config.run_id}"
      }
      |> sign_event!(config.client_private_key)

    with {:ok, client} <- RelayClient.start_link(node.websocket_url, self()),
         :ok <- await_client_connect(client) do
      try do
        case publish_event(client, node.relay_auth_url, config.client_private_key, event) do
          :ok -> {:ok, event}
          {:error, reason} -> {:error, reason}
        end
      after
        RelayClient.close(client)
      end
    end
  end

  defp wait_for_event(config, node, event_id) do
    case wait_until("event #{event_id} on #{node.websocket_url}", 20_000, 250, fn ->
           filter =
             config.filter
             |> Map.put("ids", [event_id])
             |> Map.put("limit", 1)

           case query_events(node, config.client_private_key, filter) do
             {:ok, events} ->
               if Enum.any?(events, &(&1["id"] == event_id)) do
                 {:ok, :replicated}
               else
                 {:retry, :missing_event}
               end

             {:error, reason} ->
               {:retry, reason}
           end
         end) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_sync_connected(config, node, server_id) do
    case wait_until("sync connected #{server_id}", 20_000, 250, fn ->
           case management_call(config, node, "sync_server_stats", %{"id" => server_id}) do
             {:ok, %{"connected" => true, "query_runs" => query_runs} = stats}
             when query_runs >= 1 ->
               {:ok, stats}

             {:ok, stats} ->
               {:retry, stats}

             {:error, reason} ->
               {:retry, reason}
           end
         end) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_sync_server_stats(config, node, server_id) do
    case management_call(config, node, "sync_server_stats", %{"id" => server_id}) do
      {:ok, stats} -> {:ok, stats}
      {:error, reason} -> {:error, {:sync_server_stats_failed, reason}}
    end
  end

  defp query_events(node, private_key, filter) do
    with {:ok, client} <- RelayClient.start_link(node.websocket_url, self()),
         :ok <- await_client_connect(client) do
      subscription_id = "node-sync-e2e-#{System.unique_integer([:positive, :monotonic])}"

      try do
        :ok = RelayClient.send_json(client, ["REQ", subscription_id, filter])

        authenticated_query(
          client,
          node.relay_auth_url,
          private_key,
          subscription_id,
          [filter],
          [],
          false,
          nil
        )
      after
        RelayClient.close(client)
      end
    end
  end

  defp authenticated_query(
         client,
         relay_auth_url,
         private_key,
         subscription_id,
         filters,
         events,
         authenticated?,
         auth_event_id
       ) do
    receive do
      {:node_sync_e2e_relay_client, ^client, :frame, ["AUTH", challenge]} ->
        auth_event =
          auth_event(relay_auth_url, challenge)
          |> sign_event!(private_key)

        :ok = RelayClient.send_json(client, ["AUTH", auth_event])

        authenticated_query(
          client,
          relay_auth_url,
          private_key,
          subscription_id,
          filters,
          events,
          authenticated?,
          auth_event["id"]
        )

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, true, _message]}
      when event_id == auth_event_id ->
        :ok = RelayClient.send_json(client, ["REQ", subscription_id | filters])

        authenticated_query(
          client,
          relay_auth_url,
          private_key,
          subscription_id,
          filters,
          events,
          true,
          nil
        )

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, false, message]}
      when event_id == auth_event_id ->
        {:error, {:auth_failed, message}}

      {:node_sync_e2e_relay_client, ^client, :frame, ["EVENT", ^subscription_id, event]} ->
        authenticated_query(
          client,
          relay_auth_url,
          private_key,
          subscription_id,
          filters,
          [event | events],
          authenticated?,
          auth_event_id
        )

      {:node_sync_e2e_relay_client, ^client, :frame, ["EOSE", ^subscription_id]} ->
        :ok = RelayClient.send_json(client, ["CLOSE", subscription_id])
        {:ok, Enum.reverse(events)}

      {:node_sync_e2e_relay_client, ^client, :frame, ["CLOSED", ^subscription_id, message]} ->
        cond do
          authenticated? and not auth_required_message?(message) ->
            {:error, {:subscription_closed, message}}

          auth_required_message?(message) and not is_nil(auth_event_id) ->
            authenticated_query(
              client,
              relay_auth_url,
              private_key,
              subscription_id,
              filters,
              events,
              authenticated?,
              auth_event_id
            )

          true ->
            {:error, {:subscription_closed, message}}
        end

      {:node_sync_e2e_relay_client, ^client, :frame, {:decode_error, reason, payload}} ->
        {:error, {:decode_error, reason, payload}}

      {:node_sync_e2e_relay_client, ^client, :disconnected, status} ->
        {:error, {:disconnected, status.reason}}
    after
      @frame_timeout_ms -> {:error, :query_timeout}
    end
  end

  defp publish_event(client, relay_auth_url, private_key, event) do
    :ok = RelayClient.send_json(client, ["EVENT", event])

    do_publish_event(
      client,
      relay_auth_url,
      private_key,
      event,
      Map.fetch!(event, "id"),
      false,
      nil,
      false
    )
  end

  defp do_publish_event(
         client,
         relay_auth_url,
         private_key,
         event,
         published_event_id,
         authenticated?,
         auth_event_id,
         replayed_after_auth?
       ) do
    receive do
      {:node_sync_e2e_relay_client, ^client, :frame, ["AUTH", challenge]} ->
        auth_event =
          auth_event(relay_auth_url, challenge)
          |> sign_event!(private_key)

        :ok = RelayClient.send_json(client, ["AUTH", auth_event])

        do_publish_event(
          client,
          relay_auth_url,
          private_key,
          event,
          published_event_id,
          authenticated?,
          auth_event["id"],
          replayed_after_auth?
        )

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, true, _message]}
      when event_id == auth_event_id ->
        :ok = RelayClient.send_json(client, ["EVENT", event])

        do_publish_event(
          client,
          relay_auth_url,
          private_key,
          event,
          published_event_id,
          true,
          nil,
          true
        )

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, false, message]}
      when event_id == auth_event_id ->
        {:error, {:auth_failed, message}}

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, true, _message]}
      when event_id == published_event_id ->
        :ok

      {:node_sync_e2e_relay_client, ^client, :frame, ["OK", event_id, false, message]}
      when event_id == published_event_id ->
        cond do
          authenticated? and replayed_after_auth? and not auth_required_message?(message) ->
            {:error, {:event_rejected, message}}

          auth_required_message?(message) ->
            do_publish_event(
              client,
              relay_auth_url,
              private_key,
              event,
              published_event_id,
              authenticated?,
              auth_event_id,
              replayed_after_auth?
            )

          true ->
            {:error, {:event_rejected, message}}
        end

      {:node_sync_e2e_relay_client, ^client, :frame, {:decode_error, reason, payload}} ->
        {:error, {:decode_error, reason, payload}}

      {:node_sync_e2e_relay_client, ^client, :disconnected, status} ->
        {:error, {:disconnected, status.reason}}
    after
      @frame_timeout_ms -> {:error, :publish_timeout}
    end
  end

  defp await_client_connect(client) do
    receive do
      {:node_sync_e2e_relay_client, ^client, :connected} ->
        :ok

      {:node_sync_e2e_relay_client, ^client, :disconnected, status} ->
        {:error, {:disconnected, status.reason}}
    after
      @frame_timeout_ms -> {:error, :connect_timeout}
    end
  end

  defp management_call(config, node, method, params) do
    url = node.http_url <> "/management"

    auth_header =
      nip98_event("POST", url)
      |> sign_event!(config.admin_private_key)
      |> then(&("Nostr " <> Base.encode64(JSON.encode!(&1))))

    case Req.post(
           url: url,
           headers: [{"authorization", auth_header}],
           json: %{"method" => method, "params" => params},
           decode_body: false,
           connect_options: [timeout: 1_000],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        decode_management_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:management_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_management_response(body) when is_binary(body) do
    with {:ok, %{"ok" => true, "result" => result}} <- JSON.decode(body) do
      {:ok, result}
    else
      {:ok, %{"ok" => false, "error" => error}} -> {:error, {:management_error, error}}
      {:ok, other} -> {:error, {:unexpected_management_response, other}}
      {:error, reason} -> {:error, {:invalid_management_json, reason}}
    end
  end

  defp sign_event!(event, private_key_hex) do
    {:ok, pubkey} = derive_pubkey(private_key_hex)
    seckey = Base.decode16!(String.downcase(private_key_hex), case: :lower)

    unsigned_event =
      event
      |> Map.put("pubkey", pubkey)
      |> Map.put("sig", String.duplicate("0", 128))

    id = Auth.compute_event_id(unsigned_event)

    signature =
      id
      |> Base.decode16!(case: :lower)
      |> Secp256k1.schnorr_sign(seckey)
      |> Base.encode16(case: :lower)

    unsigned_event
    |> Map.put("id", id)
    |> Map.put("sig", signature)
  end

  defp derive_pubkey(private_key_hex) do
    normalized = String.downcase(private_key_hex)

    case Base.decode16(normalized, case: :lower) do
      {:ok, <<_::256>> = seckey} ->
        pubkey =
          seckey
          |> Secp256k1.pubkey(:xonly)
          |> Base.encode16(case: :lower)

        {:ok, pubkey}

      _other ->
        {:error, {:invalid_private_key, private_key_hex}}
    end
  rescue
    _error -> {:error, {:invalid_private_key, private_key_hex}}
  end

  defp nip98_event(method, url) do
    %{
      "created_at" => System.system_time(:second),
      "kind" => 27_235,
      "tags" => [["method", method], ["u", url]],
      "content" => ""
    }
  end

  defp auth_event(relay_auth_url, challenge) do
    %{
      "created_at" => System.system_time(:second),
      "kind" => 22_242,
      "tags" => [["challenge", challenge], ["relay", relay_auth_url]],
      "content" => ""
    }
  end

  defp wait_until(label, timeout_ms, interval_ms, fun) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_until(label, timeout_ms, interval_ms, started_at, fun)
  end

  defp do_wait_until(label, timeout_ms, interval_ms, started_at, fun) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      {:retry, reason} ->
        if System.monotonic_time(:millisecond) - started_at >= timeout_ms do
          {:error, {:timeout, label, reason}}
        else
          Process.sleep(interval_ms)
          do_wait_until(label, timeout_ms, interval_ms, started_at, fun)
        end
    end
  end

  defp load_state(path) do
    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, state} when is_map(state) -> state
          {:ok, _other} -> %{}
          {:error, _reason} -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise "failed to read state file #{path}: #{inspect(reason)}"
    end
  end

  defp save_state(path, attrs) when is_binary(path) and is_map(attrs) do
    existing = load_state(path)
    merged = Map.merge(existing, attrs)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, JSON.encode!(merged)) do
      :ok
    end
  end

  defp ensure_run_matches(config, %{"run_id" => run_id}) when run_id == config.run_id, do: :ok

  defp ensure_run_matches(config, %{"run_id" => run_id}),
    do: {:error, {:run_id_mismatch, run_id, config.run_id}}

  defp ensure_run_matches(_config, %{}), do: :ok

  defp fetch_state_value(state, key) do
    case Map.fetch(state, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_state_value, key}}
    end
  end

  defp ensure_minimum_counter(stats, key, minimum) do
    case Map.get(stats, key) do
      value when is_integer(value) and value >= minimum -> :ok
      _other -> {:error, {:unexpected_sync_stats, stats}}
    end
  end

  defp auth_required_message?(message) when is_binary(message) do
    String.contains?(String.downcase(message), "auth")
  end

  defp auth_required_message?(_message), do: false

  defp default_run_id do
    "run-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp format_reason({:timeout, label, reason}),
    do: "timeout waiting for #{label}: #{inspect(reason)}"

  defp format_reason({:invalid_arguments, invalid}),
    do: "invalid arguments: #{inspect(invalid)}"

  defp format_reason({:missing_env, env_var}),
    do: "missing environment variable #{env_var}"

  defp format_reason({:unknown_command, command}),
    do: "unknown command #{command}"

  defp format_reason({:run_id_mismatch, stored_run_id, requested_run_id}),
    do: "state file run id #{stored_run_id} does not match requested run id #{requested_run_id}"

  defp format_reason({:missing_state_value, key}),
    do: "state file is missing #{key}"

  defp format_reason(:missing_command),
    do:
      "usage: elixir scripts/node_sync_e2e.exs <bootstrap|publish-resume|verify-resume> --state-file <path>"

  defp format_reason(:missing_state_file),
    do: "--state-file is required"

  defp format_reason(reason), do: inspect(reason)
end

NodeSyncE2E.Runner.main(System.argv())
