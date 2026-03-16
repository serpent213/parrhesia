defmodule Parrhesia.Web.Metrics do
  @moduledoc false

  import Plug.Conn

  alias Parrhesia.Telemetry
  alias Parrhesia.Web.Listener

  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    listener = Listener.from_conn(conn)

    if Listener.metrics_allowed?(listener, conn) do
      body = TelemetryMetricsPrometheus.Core.scrape(Telemetry.prometheus_reporter())

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, body)
    else
      send_resp(conn, 403, "forbidden")
    end
  end
end
