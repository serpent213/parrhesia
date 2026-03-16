defmodule Parrhesia.TestSupport.SyncFakeRelay.Plug do
  @moduledoc false

  import Plug.Conn

  alias Parrhesia.TestSupport.SyncFakeRelay.Server

  def init(opts), do: opts

  def call(conn, opts) do
    server = Keyword.fetch!(opts, :server)

    cond do
      conn.request_path == "/relay" and wants_nip11?(conn) ->
        send_json(conn, 200, Server.document(server))

      conn.request_path == "/relay" ->
        conn
        |> WebSockAdapter.upgrade(
          Parrhesia.TestSupport.SyncFakeRelay.Socket,
          %{server: server, relay_url: relay_url(conn)},
          timeout: 60_000
        )
        |> halt()

      true ->
        send_resp(conn, 404, "not found")
    end
  end

  defp wants_nip11?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "application/nostr+json"))
  end

  defp send_json(conn, status, body) do
    encoded = JSON.encode!(body)

    conn
    |> put_resp_content_type("application/nostr+json")
    |> send_resp(status, encoded)
  end

  defp relay_url(conn) do
    scheme = if conn.scheme == :https, do: "wss", else: "ws"
    "#{scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
  end
end
