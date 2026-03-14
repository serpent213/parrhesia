defmodule Parrhesia.Web.Metrics do
  @moduledoc false

  import Plug.Conn

  alias Parrhesia.Telemetry
  alias Parrhesia.Web.MetricsAccess

  @spec enabled_on_main_endpoint?() :: boolean()
  def enabled_on_main_endpoint? do
    :parrhesia
    |> Application.get_env(:metrics, [])
    |> Keyword.get(:enabled_on_main_endpoint, true)
  end

  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    if MetricsAccess.allowed?(conn) do
      body = TelemetryMetricsPrometheus.Core.scrape(Telemetry.prometheus_reporter())

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, body)
    else
      send_resp(conn, 403, "forbidden")
    end
  end
end
