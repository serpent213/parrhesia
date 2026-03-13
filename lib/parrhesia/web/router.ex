defmodule Parrhesia.Web.Router do
  @moduledoc false

  use Plug.Router

  alias Parrhesia.Telemetry
  alias Parrhesia.Web.Management
  alias Parrhesia.Web.Readiness
  alias Parrhesia.Web.RelayInfo

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
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
    body = TelemetryMetricsPrometheus.Core.scrape(Telemetry.prometheus_reporter())

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  post "/management" do
    Management.handle(conn)
  end

  get "/relay" do
    if accepts_nip11?(conn) do
      body = Jason.encode!(RelayInfo.document())

      conn
      |> put_resp_content_type("application/nostr+json")
      |> send_resp(200, body)
    else
      conn
      |> WebSockAdapter.upgrade(Parrhesia.Web.Connection, %{}, timeout: 60_000)
      |> halt()
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
end
