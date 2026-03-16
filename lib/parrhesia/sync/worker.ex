defmodule Parrhesia.Sync.Worker do
  @moduledoc false

  use GenServer

  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.API.Sync.Manager
  alias Parrhesia.Sync.RelayInfoClient
  alias Parrhesia.Sync.Transport.WebSockexClient

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000
  @auth_kind 22_242

  defstruct server: nil,
            manager: nil,
            transport_module: WebSockexClient,
            transport_pid: nil,
            phase: :idle,
            current_subscription_id: nil,
            backoff_ms: @initial_backoff_ms,
            authenticated?: false,
            auth_event_id: nil,
            resubscribe_after_auth?: false,
            cursor_created_at: nil,
            cursor_event_id: nil,
            relay_info_opts: [],
            transport_opts: []

  @type t :: %__MODULE__{}

  def child_spec(opts) do
    server = Keyword.fetch!(opts, :server)

    %{
      id: {:sync_worker, server.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_now(worker), do: GenServer.cast(worker, :sync_now)
  def stop(worker), do: GenServer.stop(worker, :normal)

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    runtime = Keyword.get(opts, :runtime, %{})

    state = %__MODULE__{
      server: server,
      manager: Keyword.fetch!(opts, :manager),
      transport_module: Keyword.get(opts, :transport_module, WebSockexClient),
      cursor_created_at: Map.get(runtime, :cursor_created_at),
      cursor_event_id: Map.get(runtime, :cursor_event_id),
      relay_info_opts: Keyword.get(opts, :relay_info_opts, []),
      transport_opts: Keyword.get(opts, :transport_opts, [])
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    Manager.runtime_event(state.manager, state.server.id, :subscription_restart)

    next_state =
      state
      |> close_subscription()
      |> issue_subscription()

    {:noreply, next_state}
  end

  @impl true
  def handle_info(:connect, %__MODULE__{transport_pid: nil} = state) do
    case RelayInfoClient.verify_remote_identity(state.server, state.relay_info_opts) do
      :ok ->
        connect_transport(state)

      {:error, reason} ->
        Manager.runtime_event(state.manager, state.server.id, :disconnected, %{reason: reason})
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:sync_transport, transport_pid, :connected, _info}, state) do
    Manager.runtime_event(state.manager, state.server.id, :connected, %{})

    next_state =
      state
      |> Map.put(:transport_pid, transport_pid)
      |> Map.put(:backoff_ms, @initial_backoff_ms)
      |> Map.put(:authenticated?, false)
      |> Map.put(:auth_event_id, nil)
      |> Map.put(:resubscribe_after_auth?, false)
      |> issue_subscription()

    {:noreply, next_state}
  end

  def handle_info({:sync_transport, _transport_pid, :frame, frame}, state) do
    {:noreply, handle_transport_frame(state, frame)}
  end

  def handle_info({:sync_transport, _transport_pid, :disconnected, status}, state) do
    Manager.runtime_event(state.manager, state.server.id, :disconnected, %{reason: status.reason})

    next_state =
      state
      |> Map.put(:transport_pid, nil)
      |> Map.put(:phase, :idle)
      |> Map.put(:authenticated?, false)
      |> Map.put(:auth_event_id, nil)
      |> Map.put(:resubscribe_after_auth?, false)
      |> Map.put(:current_subscription_id, nil)
      |> schedule_reconnect()

    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connect_transport(state) do
    case state.transport_module.connect(self(), state.server, state.transport_opts) do
      {:ok, transport_pid} ->
        {:noreply, %{state | transport_pid: transport_pid, phase: :connecting}}

      {:error, reason} ->
        Manager.runtime_event(state.manager, state.server.id, :disconnected, %{reason: reason})
        {:noreply, schedule_reconnect(state)}
    end
  end

  defp handle_transport_frame(state, ["AUTH", challenge]) when is_binary(challenge) do
    case send_auth_event(state, challenge) do
      {:ok, auth_event_id} ->
        %{state | auth_event_id: auth_event_id, phase: :authenticating}

      {:error, reason} ->
        Manager.runtime_event(state.manager, state.server.id, :error, %{reason: reason})
        state
    end
  end

  defp handle_transport_frame(state, ["OK", event_id, true, _message])
       when event_id == state.auth_event_id do
    next_state = %{state | authenticated?: true, auth_event_id: nil}

    if next_state.resubscribe_after_auth? do
      next_state
      |> Map.put(:resubscribe_after_auth?, false)
      |> issue_subscription()
    else
      next_state
    end
  end

  defp handle_transport_frame(state, ["OK", event_id, false, message])
       when event_id == state.auth_event_id do
    Manager.runtime_event(state.manager, state.server.id, :error, %{reason: message})
    schedule_reconnect(%{state | auth_event_id: nil, authenticated?: false})
  end

  defp handle_transport_frame(state, ["EVENT", subscription_id, event])
       when subscription_id == state.current_subscription_id and is_map(event) do
    handle_remote_event(state, event)
  end

  defp handle_transport_frame(state, ["EOSE", subscription_id])
       when subscription_id == state.current_subscription_id do
    Manager.runtime_event(state.manager, state.server.id, :sync_completed, %{})
    %{state | phase: :streaming}
  end

  defp handle_transport_frame(state, ["CLOSED", subscription_id, message])
       when subscription_id == state.current_subscription_id do
    auth_required? = is_binary(message) and String.contains?(String.downcase(message), "auth")

    next_state =
      state
      |> Map.put(:current_subscription_id, nil)
      |> Map.put(:phase, :idle)

    if auth_required? and not state.authenticated? do
      %{next_state | resubscribe_after_auth?: true}
    else
      Manager.runtime_event(state.manager, state.server.id, :error, %{reason: message})
      schedule_reconnect(next_state)
    end
  end

  defp handle_transport_frame(state, {:decode_error, reason, _payload}) do
    Manager.runtime_event(state.manager, state.server.id, :error, %{reason: reason})
    state
  end

  defp handle_transport_frame(state, _frame), do: state

  defp issue_subscription(%__MODULE__{transport_pid: nil} = state), do: state

  defp issue_subscription(state) do
    subscription_id = subscription_id(state.server.id)
    filters = sync_filters(state)

    :ok =
      state.transport_module.send_json(state.transport_pid, ["REQ", subscription_id | filters])

    Manager.runtime_event(state.manager, state.server.id, :sync_started, %{})

    %{
      state
      | current_subscription_id: subscription_id,
        phase: :catchup
    }
  end

  defp close_subscription(%__MODULE__{transport_pid: nil} = state), do: state
  defp close_subscription(%__MODULE__{current_subscription_id: nil} = state), do: state

  defp close_subscription(state) do
    :ok =
      state.transport_module.send_json(state.transport_pid, [
        "CLOSE",
        state.current_subscription_id
      ])

    %{state | current_subscription_id: nil}
  end

  defp send_auth_event(state, challenge) do
    event = %{
      "created_at" => System.system_time(:second),
      "kind" => @auth_kind,
      "tags" => [["challenge", challenge], ["relay", state.server.url]],
      "content" => ""
    }

    with {:ok, signed_event} <- Identity.sign_event(event) do
      :ok = state.transport_module.send_json(state.transport_pid, ["AUTH", signed_event])
      {:ok, signed_event["id"]}
    end
  end

  defp handle_remote_event(state, event) do
    context = request_context(state)

    case Events.publish(event, context: context) do
      {:ok, %{accepted: true}} ->
        Manager.runtime_event(state.manager, state.server.id, :event_result, %{
          result: :accepted,
          event: event
        })

        advance_cursor(state, event)

      {:ok, %{accepted: false, reason: :duplicate_event}} ->
        Manager.runtime_event(state.manager, state.server.id, :event_result, %{
          result: :duplicate,
          event: event
        })

        advance_cursor(state, event)

      {:ok, %{accepted: false, reason: reason}} ->
        Manager.runtime_event(state.manager, state.server.id, :event_result, %{
          result: :rejected,
          event: event,
          reason: reason
        })

        state

      {:error, reason} ->
        Manager.runtime_event(state.manager, state.server.id, :event_result, %{
          result: :rejected,
          event: event,
          reason: reason
        })

        state
    end
  end

  defp request_context(state) do
    %RequestContext{
      authenticated_pubkeys: MapSet.new([state.server.auth_pubkey]),
      caller: :sync,
      subscription_id: state.current_subscription_id,
      peer_id: state.server.id,
      metadata: %{
        sync_server_id: state.server.id,
        remote_url: state.server.url
      }
    }
  end

  defp advance_cursor(state, event) do
    created_at = Map.get(event, "created_at")
    event_id = Map.get(event, "id")

    if newer_cursor?(state.cursor_created_at, state.cursor_event_id, created_at, event_id) do
      Manager.runtime_event(state.manager, state.server.id, :cursor_advanced, %{
        created_at: created_at,
        event_id: event_id
      })

      %{state | cursor_created_at: created_at, cursor_event_id: event_id}
    else
      state
    end
  end

  defp newer_cursor?(nil, _cursor_event_id, created_at, event_id),
    do: is_integer(created_at) and is_binary(event_id)

  defp newer_cursor?(cursor_created_at, cursor_event_id, created_at, event_id) do
    cond do
      not is_integer(created_at) or not is_binary(event_id) ->
        false

      created_at > cursor_created_at ->
        true

      created_at == cursor_created_at and is_binary(cursor_event_id) and
          event_id > cursor_event_id ->
        true

      true ->
        false
    end
  end

  defp sync_filters(state) do
    Enum.map(state.server.filters, fn filter ->
      case since_value(state, filter) do
        nil -> filter
        since -> Map.put(filter, "since", since)
      end
    end)
  end

  defp since_value(%__MODULE__{cursor_created_at: nil}, _filter), do: nil

  defp since_value(state, _filter) do
    max(state.cursor_created_at - state.server.overlap_window_seconds, 0)
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff_ms)
    %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}
  end

  defp subscription_id(server_id) do
    "sync-#{server_id}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
