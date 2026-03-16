defmodule Parrhesia.API.Sync.Manager do
  @moduledoc false

  use GenServer

  alias Parrhesia.API.Sync
  alias Parrhesia.Protocol.Filter

  require Logger

  @default_overlap_window_seconds 300
  @default_mode :req_stream
  @default_auth_type :nip42
  @default_tls_mode :required
  @hex64 ~r/\A[0-9a-f]{64}\z/

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put_server(name, server) do
    GenServer.call(name, {:put_server, server})
  end

  def remove_server(name, server_id) do
    GenServer.call(name, {:remove_server, server_id})
  end

  def get_server(name, server_id) do
    GenServer.call(name, {:get_server, server_id})
  end

  def list_servers(name) do
    GenServer.call(name, :list_servers)
  end

  def start_server(name, server_id) do
    GenServer.call(name, {:start_server, server_id})
  end

  def stop_server(name, server_id) do
    GenServer.call(name, {:stop_server, server_id})
  end

  def sync_now(name, server_id) do
    GenServer.call(name, {:sync_now, server_id})
  end

  def server_stats(name, server_id) do
    GenServer.call(name, {:server_stats, server_id})
  end

  def sync_stats(name) do
    GenServer.call(name, :sync_stats)
  end

  def sync_health(name) do
    GenServer.call(name, :sync_health)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, config_path() || Sync.default_path())
    {:ok, load_state(path)}
  end

  @impl true
  def handle_call({:put_server, server}, _from, state) do
    case normalize_server(server) do
      {:ok, normalized_server} ->
        updated_state = put_server_state(state, normalized_server)

        with :ok <- persist_state(updated_state) do
          {:reply, {:ok, merged_server(updated_state, normalized_server.id)}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_server, server_id}, _from, state) do
    if Map.has_key?(state.servers, server_id) do
      updated_state = %{
        state
        | servers: Map.delete(state.servers, server_id),
          runtime: Map.delete(state.runtime, server_id)
      }

      with :ok <- persist_state(updated_state) do
        {:reply, :ok, updated_state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_server, server_id}, _from, state) do
    case Map.fetch(state.servers, server_id) do
      {:ok, _server} -> {:reply, {:ok, merged_server(state, server_id)}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list_servers, _from, state) do
    servers =
      state.servers
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&merged_server(state, &1))

    {:reply, {:ok, servers}, state}
  end

  def handle_call({:start_server, server_id}, _from, state) do
    with {:ok, updated_state} <- update_runtime(state, server_id, &mark_running/1),
         :ok <- persist_state(updated_state) do
      {:reply, :ok, updated_state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_server, server_id}, _from, state) do
    with {:ok, updated_state} <- update_runtime(state, server_id, &mark_stopped/1),
         :ok <- persist_state(updated_state) do
      {:reply, :ok, updated_state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sync_now, server_id}, _from, state) do
    with {:ok, updated_state} <- update_runtime(state, server_id, &record_sync_now/1),
         :ok <- persist_state(updated_state) do
      {:reply, :ok, updated_state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:server_stats, server_id}, _from, state) do
    case Map.fetch(state.runtime, server_id) do
      {:ok, runtime} -> {:reply, {:ok, runtime_stats(runtime)}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:sync_stats, _from, state) do
    {:reply, {:ok, aggregate_stats(state)}, state}
  end

  def handle_call(:sync_health, _from, state) do
    {:reply, {:ok, health_summary(state)}, state}
  end

  defp put_server_state(state, server) do
    runtime =
      case Map.get(state.runtime, server.id) do
        nil -> default_runtime(server)
        existing_runtime -> maybe_align_runtime_with_server(existing_runtime, server)
      end

    %{
      state
      | servers: Map.put(state.servers, server.id, server),
        runtime: Map.put(state.runtime, server.id, runtime)
    }
  end

  defp maybe_align_runtime_with_server(runtime, %{enabled?: false}) do
    runtime
    |> Map.put(:state, :stopped)
    |> Map.put(:connected?, false)
    |> Map.put(:last_disconnected_at, now())
  end

  defp maybe_align_runtime_with_server(runtime, _server), do: runtime

  defp default_runtime(server) do
    %{
      server_id: server.id,
      state: if(server.enabled?, do: :running, else: :stopped),
      connected?: false,
      last_connected_at: nil,
      last_disconnected_at: nil,
      last_sync_started_at: nil,
      last_sync_completed_at: nil,
      last_event_received_at: nil,
      last_eose_at: nil,
      reconnect_attempts: 0,
      last_error: nil,
      events_received: 0,
      events_accepted: 0,
      events_duplicate: 0,
      events_rejected: 0,
      query_runs: 0,
      subscription_restarts: 0,
      reconnects: 0,
      last_remote_eose_at: nil
    }
  end

  defp mark_running(runtime) do
    runtime
    |> Map.put(:state, :running)
    |> Map.put(:last_error, nil)
  end

  defp mark_stopped(runtime) do
    runtime
    |> Map.put(:state, :stopped)
    |> Map.put(:connected?, false)
    |> Map.put(:last_disconnected_at, now())
  end

  defp record_sync_now(runtime) do
    sync_timestamp = now()

    runtime
    |> Map.update!(:query_runs, &(&1 + 1))
    |> Map.put(:last_sync_started_at, sync_timestamp)
    |> Map.put(:last_sync_completed_at, sync_timestamp)
  end

  defp update_runtime(state, server_id, fun) do
    case Map.fetch(state.runtime, server_id) do
      {:ok, runtime} ->
        updated_runtime = fun.(runtime)
        {:ok, %{state | runtime: Map.put(state.runtime, server_id, updated_runtime)}}

      :error ->
        :error
    end
  end

  defp merged_server(state, server_id) do
    state.servers
    |> Map.fetch!(server_id)
    |> Map.put(:runtime, Map.fetch!(state.runtime, server_id))
  end

  defp runtime_stats(runtime) do
    %{
      "server_id" => runtime.server_id,
      "state" => Atom.to_string(runtime.state),
      "connected" => runtime.connected?,
      "events_received" => runtime.events_received,
      "events_accepted" => runtime.events_accepted,
      "events_duplicate" => runtime.events_duplicate,
      "events_rejected" => runtime.events_rejected,
      "query_runs" => runtime.query_runs,
      "subscription_restarts" => runtime.subscription_restarts,
      "reconnects" => runtime.reconnects,
      "last_sync_started_at" => runtime.last_sync_started_at,
      "last_sync_completed_at" => runtime.last_sync_completed_at,
      "last_remote_eose_at" => runtime.last_remote_eose_at,
      "last_error" => runtime.last_error
    }
  end

  defp aggregate_stats(state) do
    runtimes = Map.values(state.runtime)

    %{
      "servers_total" => map_size(state.servers),
      "servers_enabled" => Enum.count(state.servers, fn {_id, server} -> server.enabled? end),
      "servers_running" => Enum.count(runtimes, &(&1.state == :running)),
      "servers_connected" => Enum.count(runtimes, & &1.connected?),
      "events_received" => Enum.reduce(runtimes, 0, &(&1.events_received + &2)),
      "events_accepted" => Enum.reduce(runtimes, 0, &(&1.events_accepted + &2)),
      "events_duplicate" => Enum.reduce(runtimes, 0, &(&1.events_duplicate + &2)),
      "events_rejected" => Enum.reduce(runtimes, 0, &(&1.events_rejected + &2)),
      "query_runs" => Enum.reduce(runtimes, 0, &(&1.query_runs + &2)),
      "subscription_restarts" => Enum.reduce(runtimes, 0, &(&1.subscription_restarts + &2)),
      "reconnects" => Enum.reduce(runtimes, 0, &(&1.reconnects + &2))
    }
  end

  defp health_summary(state) do
    failing_servers =
      state.runtime
      |> Enum.flat_map(fn {server_id, runtime} ->
        if is_binary(runtime.last_error) and runtime.last_error != "" do
          [%{"id" => server_id, "reason" => runtime.last_error}]
        else
          []
        end
      end)

    %{
      "status" => if(failing_servers == [], do: "ok", else: "degraded"),
      "servers_total" => map_size(state.servers),
      "servers_connected" =>
        Enum.count(state.runtime, fn {_id, runtime} -> runtime.connected? end),
      "servers_failing" => failing_servers
    }
  end

  defp load_state(path) do
    case File.read(path) do
      {:ok, payload} ->
        case decode_persisted_state(payload, path) do
          {:ok, state} ->
            state

          {:error, reason} ->
            Logger.warning("failed to load sync state from #{path}: #{inspect(reason)}")
            empty_state(path)
        end

      {:error, :enoent} ->
        empty_state(path)

      {:error, reason} ->
        Logger.warning("failed to read sync state from #{path}: #{inspect(reason)}")
        empty_state(path)
    end
  end

  defp decode_persisted_state(payload, path) do
    with {:ok, decoded} <- JSON.decode(payload),
         {:ok, servers} <- decode_servers(Map.get(decoded, "servers", %{})),
         {:ok, runtime} <- decode_runtime(Map.get(decoded, "runtime", %{}), servers) do
      {:ok, %{path: path, servers: servers, runtime: runtime}}
    end
  end

  defp decode_servers(servers) when is_map(servers) do
    Enum.reduce_while(servers, {:ok, %{}}, fn {_id, server_payload}, {:ok, acc} ->
      case normalize_server(server_payload) do
        {:ok, server} -> {:cont, {:ok, Map.put(acc, server.id, server)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_servers(_servers), do: {:error, :invalid_servers_state}

  defp decode_runtime(runtime_payload, servers)
       when is_map(runtime_payload) and is_map(servers) do
    runtime =
      Enum.reduce(servers, %{}, fn {server_id, server}, acc ->
        decoded_runtime =
          runtime_payload
          |> Map.get(server_id)
          |> normalize_runtime(server)

        Map.put(acc, server_id, decoded_runtime)
      end)

    {:ok, runtime}
  end

  defp decode_runtime(_runtime_payload, _servers), do: {:error, :invalid_runtime_state}

  defp normalize_runtime(nil, server), do: default_runtime(server)

  defp normalize_runtime(runtime, server) when is_map(runtime) do
    state =
      runtime
      |> Map.put(:server_id, server.id)
      |> Map.put(:state, normalize_runtime_state(fetch_value(runtime, :state)))
      |> Map.put(:connected?, fetch_boolean(runtime, :connected?) || false)
      |> Map.put(:last_connected_at, fetch_string_or_nil(runtime, :last_connected_at))
      |> Map.put(:last_disconnected_at, fetch_string_or_nil(runtime, :last_disconnected_at))
      |> Map.put(:last_sync_started_at, fetch_string_or_nil(runtime, :last_sync_started_at))
      |> Map.put(:last_sync_completed_at, fetch_string_or_nil(runtime, :last_sync_completed_at))
      |> Map.put(:last_event_received_at, fetch_string_or_nil(runtime, :last_event_received_at))
      |> Map.put(:last_eose_at, fetch_string_or_nil(runtime, :last_eose_at))
      |> Map.put(:last_remote_eose_at, fetch_string_or_nil(runtime, :last_remote_eose_at))
      |> Map.put(:last_error, fetch_string_or_nil(runtime, :last_error))
      |> Map.put(:reconnect_attempts, fetch_non_neg_integer(runtime, :reconnect_attempts))
      |> Map.put(:events_received, fetch_non_neg_integer(runtime, :events_received))
      |> Map.put(:events_accepted, fetch_non_neg_integer(runtime, :events_accepted))
      |> Map.put(:events_duplicate, fetch_non_neg_integer(runtime, :events_duplicate))
      |> Map.put(:events_rejected, fetch_non_neg_integer(runtime, :events_rejected))
      |> Map.put(:query_runs, fetch_non_neg_integer(runtime, :query_runs))
      |> Map.put(:subscription_restarts, fetch_non_neg_integer(runtime, :subscription_restarts))
      |> Map.put(:reconnects, fetch_non_neg_integer(runtime, :reconnects))

    maybe_align_runtime_with_server(state, server)
  end

  defp normalize_runtime(_runtime, server), do: default_runtime(server)

  defp persist_state(%{path: path} = state) do
    temp_path = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, JSON.encode!(encode_state(state))),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  defp encode_state(state) do
    %{
      "version" => 1,
      "servers" =>
        Map.new(state.servers, fn {server_id, server} -> {server_id, encode_server(server)} end),
      "runtime" =>
        Map.new(state.runtime, fn {server_id, runtime} -> {server_id, encode_runtime(runtime)} end)
    }
  end

  defp encode_server(server) do
    %{
      "id" => server.id,
      "url" => server.url,
      "enabled?" => server.enabled?,
      "auth_pubkey" => server.auth_pubkey,
      "filters" => server.filters,
      "mode" => Atom.to_string(server.mode),
      "overlap_window_seconds" => server.overlap_window_seconds,
      "auth" => %{"type" => Atom.to_string(server.auth.type)},
      "tls" => %{
        "mode" => Atom.to_string(server.tls.mode),
        "hostname" => server.tls.hostname,
        "pins" =>
          Enum.map(server.tls.pins, fn pin ->
            %{
              "type" => Atom.to_string(pin.type),
              "value" => pin.value
            }
          end)
      },
      "metadata" => server.metadata
    }
  end

  defp encode_runtime(runtime) do
    %{
      "server_id" => runtime.server_id,
      "state" => Atom.to_string(runtime.state),
      "connected?" => runtime.connected?,
      "last_connected_at" => runtime.last_connected_at,
      "last_disconnected_at" => runtime.last_disconnected_at,
      "last_sync_started_at" => runtime.last_sync_started_at,
      "last_sync_completed_at" => runtime.last_sync_completed_at,
      "last_event_received_at" => runtime.last_event_received_at,
      "last_eose_at" => runtime.last_eose_at,
      "reconnect_attempts" => runtime.reconnect_attempts,
      "last_error" => runtime.last_error,
      "events_received" => runtime.events_received,
      "events_accepted" => runtime.events_accepted,
      "events_duplicate" => runtime.events_duplicate,
      "events_rejected" => runtime.events_rejected,
      "query_runs" => runtime.query_runs,
      "subscription_restarts" => runtime.subscription_restarts,
      "reconnects" => runtime.reconnects,
      "last_remote_eose_at" => runtime.last_remote_eose_at
    }
  end

  defp empty_state(path) do
    %{path: path, servers: %{}, runtime: %{}}
  end

  defp normalize_server(server) when is_map(server) do
    with {:ok, id} <- normalize_non_empty_string(fetch_value(server, :id), :invalid_server_id),
         {:ok, {url, host}} <- normalize_url(fetch_value(server, :url)),
         {:ok, enabled?} <- normalize_boolean(fetch_value(server, :enabled?), true),
         {:ok, auth_pubkey} <- normalize_pubkey(fetch_value(server, :auth_pubkey)),
         {:ok, filters} <- normalize_filters(fetch_value(server, :filters)),
         {:ok, mode} <- normalize_mode(fetch_value(server, :mode)),
         {:ok, overlap_window_seconds} <-
           normalize_overlap_window(fetch_value(server, :overlap_window_seconds)),
         {:ok, auth} <- normalize_auth(fetch_value(server, :auth)),
         {:ok, tls} <- normalize_tls(fetch_value(server, :tls), host),
         {:ok, metadata} <- normalize_metadata(fetch_value(server, :metadata)) do
      {:ok,
       %{
         id: id,
         url: url,
         enabled?: enabled?,
         auth_pubkey: auth_pubkey,
         filters: filters,
         mode: mode,
         overlap_window_seconds: overlap_window_seconds,
         auth: auth,
         tls: tls,
         metadata: metadata
       }}
    end
  end

  defp normalize_server(_server), do: {:error, :invalid_server}

  defp normalize_url(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    if uri.scheme in ["ws", "wss"] and is_binary(uri.host) and uri.host != "" do
      {:ok, {URI.to_string(uri), uri.host}}
    else
      {:error, :invalid_url}
    end
  end

  defp normalize_url(_url), do: {:error, :invalid_url}

  defp normalize_pubkey(pubkey) when is_binary(pubkey) do
    normalized = String.downcase(pubkey)

    if String.match?(normalized, @hex64) do
      {:ok, normalized}
    else
      {:error, :invalid_auth_pubkey}
    end
  end

  defp normalize_pubkey(_pubkey), do: {:error, :invalid_auth_pubkey}

  defp normalize_filters(filters) when is_list(filters) do
    normalized_filters = Enum.map(filters, &normalize_filter_map/1)

    with :ok <- Filter.validate_filters(normalized_filters) do
      {:ok, normalized_filters}
    end
  end

  defp normalize_filters(_filters), do: {:error, :invalid_filters}

  defp normalize_mode(nil), do: {:ok, @default_mode}
  defp normalize_mode(:req_stream), do: {:ok, :req_stream}
  defp normalize_mode("req_stream"), do: {:ok, :req_stream}
  defp normalize_mode(_mode), do: {:error, :invalid_mode}

  defp normalize_overlap_window(nil), do: {:ok, @default_overlap_window_seconds}

  defp normalize_overlap_window(seconds) when is_integer(seconds) and seconds >= 0,
    do: {:ok, seconds}

  defp normalize_overlap_window(_seconds), do: {:error, :invalid_overlap_window_seconds}

  defp normalize_auth(nil), do: {:ok, %{type: @default_auth_type}}

  defp normalize_auth(auth) when is_map(auth) do
    with {:ok, type} <- normalize_auth_type(fetch_value(auth, :type)) do
      {:ok, %{type: type}}
    end
  end

  defp normalize_auth(_auth), do: {:error, :invalid_auth}

  defp normalize_auth_type(nil), do: {:ok, @default_auth_type}
  defp normalize_auth_type(:nip42), do: {:ok, :nip42}
  defp normalize_auth_type("nip42"), do: {:ok, :nip42}
  defp normalize_auth_type(_type), do: {:error, :invalid_auth_type}

  defp normalize_tls(tls, host) when is_map(tls) do
    with {:ok, mode} <- normalize_tls_mode(fetch_value(tls, :mode)),
         {:ok, hostname} <- normalize_hostname(fetch_value(tls, :hostname) || host),
         {:ok, pins} <- normalize_tls_pins(fetch_value(tls, :pins)) do
      {:ok, %{mode: mode, hostname: hostname, pins: pins}}
    end
  end

  defp normalize_tls(_tls, _host), do: {:error, :invalid_tls}

  defp normalize_tls_mode(nil), do: {:ok, @default_tls_mode}
  defp normalize_tls_mode(:required), do: {:ok, :required}
  defp normalize_tls_mode("required"), do: {:ok, :required}
  defp normalize_tls_mode(_mode), do: {:error, :invalid_tls_mode}

  defp normalize_hostname(hostname) when is_binary(hostname) and hostname != "",
    do: {:ok, hostname}

  defp normalize_hostname(_hostname), do: {:error, :invalid_tls_hostname}

  defp normalize_tls_pins(pins) when is_list(pins) and pins != [] do
    Enum.reduce_while(pins, {:ok, []}, fn pin, {:ok, acc} ->
      case normalize_tls_pin(pin) do
        {:ok, normalized_pin} -> {:cont, {:ok, [normalized_pin | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_pins} -> {:ok, Enum.reverse(normalized_pins)}
      error -> error
    end
  end

  defp normalize_tls_pins(_pins), do: {:error, :invalid_tls_pins}

  defp normalize_tls_pin(pin) when is_map(pin) do
    with {:ok, type} <- normalize_tls_pin_type(fetch_value(pin, :type)),
         {:ok, value} <- normalize_non_empty_string(fetch_value(pin, :value), :invalid_tls_pin) do
      {:ok, %{type: type, value: value}}
    end
  end

  defp normalize_tls_pin(_pin), do: {:error, :invalid_tls_pin}

  defp normalize_tls_pin_type(:spki_sha256), do: {:ok, :spki_sha256}
  defp normalize_tls_pin_type("spki_sha256"), do: {:ok, :spki_sha256}
  defp normalize_tls_pin_type(_type), do: {:error, :invalid_tls_pin}

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(_metadata), do: {:error, :invalid_metadata}

  defp normalize_boolean(nil, default), do: {:ok, default}
  defp normalize_boolean(value, _default) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value, _default), do: {:error, :invalid_enabled_flag}

  defp normalize_non_empty_string(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_non_empty_string(_value, reason), do: {:error, reason}

  defp normalize_filter_map(filter) when is_map(filter) do
    Map.new(filter, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_filter_map(filter), do: filter

  defp normalize_runtime_state("running"), do: :running
  defp normalize_runtime_state(:running), do: :running
  defp normalize_runtime_state("stopped"), do: :stopped
  defp normalize_runtime_state(:stopped), do: :stopped
  defp normalize_runtime_state(_state), do: :stopped

  defp fetch_non_neg_integer(map, key) do
    case fetch_value(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp fetch_boolean(map, key) do
    case fetch_value(map, key) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp fetch_string_or_nil(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp config_path do
    :parrhesia
    |> Application.get_env(:sync, [])
    |> Keyword.get(:path)
  end

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
