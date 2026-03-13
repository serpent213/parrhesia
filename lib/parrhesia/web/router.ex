defmodule Parrhesia.Web.Router do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/relay" do
    conn
    |> WebSockAdapter.upgrade(Parrhesia.Web.Connection, %{}, timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
