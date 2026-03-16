defmodule Parrhesia.Sync.Transport.WebSockexClient do
  @moduledoc false

  use WebSockex

  alias Parrhesia.Sync.TLS

  @behaviour Parrhesia.Sync.Transport

  @impl true
  def connect(owner, server, opts \\ []) do
    state = %{
      owner: owner,
      server: server
    }

    transport_opts =
      server.tls
      |> TLS.websocket_options()
      |> Keyword.merge(Keyword.get(opts, :websocket_opts, []))
      |> Keyword.put(:handle_initial_conn_failure, true)

    WebSockex.start(server.url, __MODULE__, state, transport_opts)
  end

  @impl true
  def send_json(pid, payload) do
    WebSockex.cast(pid, {:send_json, payload})
  end

  @impl true
  def close(pid) do
    WebSockex.cast(pid, :close)
    :ok
  end

  @impl true
  def handle_connect(conn, state) do
    send(state.owner, {:sync_transport, self(), :connected, %{resp_headers: conn.resp_headers}})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    message =
      case JSON.decode(payload) do
        {:ok, frame} -> frame
        {:error, reason} -> {:decode_error, reason, payload}
      end

    send(state.owner, {:sync_transport, self(), :frame, message})
    {:ok, state}
  end

  def handle_frame(frame, state) do
    send(state.owner, {:sync_transport, self(), :frame, frame})
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_json, payload}, state) do
    {:reply, {:text, JSON.encode!(payload)}, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_disconnect(status, state) do
    send(state.owner, {:sync_transport, self(), :disconnected, status})
    {:ok, state}
  end
end
