defmodule Parrhesia.Web.Router do
  @moduledoc false

  use Plug.Router

  alias Parrhesia.Policy.ConnectionPolicy
  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.Management
  alias Parrhesia.Web.Metrics
  alias Parrhesia.Web.Readiness
  alias Parrhesia.Web.RelayInfo

  plug(:put_listener)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: JSON
  )

  plug(Parrhesia.Web.RemoteIp)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/ready" do
    if Readiness.ready?() do
      send_resp(conn, 200, "ready")
    else
      send_resp(conn, 503, "not-ready")
    end
  end

  get "/metrics" do
    listener = Listener.from_conn(conn)

    if Listener.feature_enabled?(listener, :metrics) do
      case authorize_listener_request(conn, listener) do
        :ok -> Metrics.handle(conn)
        {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/management" do
    listener = Listener.from_conn(conn)

    if Listener.feature_enabled?(listener, :admin) do
      case authorize_listener_request(conn, listener) do
        :ok -> Management.handle(conn, listener: listener)
        {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/relay" do
    listener = Listener.from_conn(conn)

    if Listener.feature_enabled?(listener, :nostr) do
      case authorize_listener_request(conn, listener) do
        :ok ->
          if accepts_nip11?(conn) do
            body = JSON.encode!(RelayInfo.document(listener))

            conn
            |> put_resp_content_type("application/nostr+json")
            |> send_resp(200, body)
          else
            conn
            |> WebSockAdapter.upgrade(
              Parrhesia.Web.Connection,
              %{
                listener: listener,
                relay_url: Listener.relay_url(listener, conn),
                remote_ip: remote_ip(conn)
              },
              timeout: 60_000,
              max_frame_size: max_frame_bytes()
            )
            |> halt()
          end

        {:error, :forbidden} ->
          send_resp(conn, 403, "forbidden")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp put_listener(conn, opts) do
    case conn.private do
      %{parrhesia_listener: _listener} -> conn
      _other -> Listener.put_conn(conn, opts)
    end
  end

  defp accepts_nip11?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "application/nostr+json"))
  end

  defp max_frame_bytes do
    Parrhesia.Config.get([:limits, :max_frame_bytes], 1_048_576)
  end

  defp authorize_listener_request(conn, listener) do
    with :ok <- authorize_remote_ip(conn),
         true <- Listener.remote_ip_allowed?(listener, conn.remote_ip) do
      :ok
    else
      {:error, :ip_blocked} -> {:error, :forbidden}
      false -> {:error, :forbidden}
    end
  end

  defp authorize_remote_ip(conn) do
    ConnectionPolicy.authorize_remote_ip(conn.remote_ip)
  end

  defp remote_ip(conn) do
    case conn.remote_ip do
      {_, _, _, _} = remote_ip -> :inet.ntoa(remote_ip) |> to_string()
      {_, _, _, _, _, _, _, _} = remote_ip -> :inet.ntoa(remote_ip) |> to_string()
      _other -> nil
    end
  end
end
