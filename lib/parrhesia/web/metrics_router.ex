defmodule Parrhesia.Web.MetricsRouter do
  @moduledoc false

  use Plug.Router

  alias Parrhesia.Web.Metrics

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    Metrics.handle(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
