defmodule Parrhesia.Web.Router do
  @moduledoc false

  use Plug.Router

  alias Parrhesia.Policy.ConnectionPolicy
  alias Parrhesia.Web.Management
  alias Parrhesia.Web.Metrics
  alias Parrhesia.Web.Readiness
  alias Parrhesia.Web.RelayInfo

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: JSON
  )

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
    if Metrics.enabled_on_main_endpoint?() do
      Metrics.handle(conn)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/management" do
    case ConnectionPolicy.authorize_remote_ip(conn.remote_ip) do
      :ok -> Management.handle(conn)
      {:error, :ip_blocked} -> send_resp(conn, 403, "forbidden")
    end
  end

  get "/relay" do
    case ConnectionPolicy.authorize_remote_ip(conn.remote_ip) do
      :ok ->
        if accepts_nip11?(conn) do
          body = JSON.encode!(RelayInfo.document())

          conn
          |> put_resp_content_type("application/nostr+json")
          |> send_resp(200, body)
        else
          conn
          |> WebSockAdapter.upgrade(
            Parrhesia.Web.Connection,
            %{relay_url: relay_url(conn), remote_ip: remote_ip(conn)},
            timeout: 60_000,
            max_frame_size: max_frame_bytes()
          )
          |> halt()
        end

      {:error, :ip_blocked} ->
        send_resp(conn, 403, "forbidden")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp accepts_nip11?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "application/nostr+json"))
  end

  defp relay_url(conn) do
    ws_scheme = if conn.scheme == :https, do: "wss", else: "ws"

    port_segment =
      if default_http_port?(conn.scheme, conn.port) do
        ""
      else
        ":#{conn.port}"
      end

    "#{ws_scheme}://#{conn.host}#{port_segment}#{conn.request_path}"
  end

  defp default_http_port?(:http, 80), do: true
  defp default_http_port?(:https, 443), do: true
  defp default_http_port?(_scheme, _port), do: false

  defp max_frame_bytes do
    Parrhesia.Config.get([:limits, :max_frame_bytes], 1_048_576)
  end

  defp remote_ip(conn) do
    case conn.remote_ip do
      {_, _, _, _} = remote_ip -> :inet.ntoa(remote_ip) |> to_string()
      {_, _, _, _, _, _, _, _} = remote_ip -> :inet.ntoa(remote_ip) |> to_string()
      _other -> nil
    end
  end
end
