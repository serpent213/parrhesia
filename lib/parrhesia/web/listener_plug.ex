defmodule Parrhesia.Web.ListenerPlug do
  @moduledoc false

  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.Router

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Listener.put_conn(opts)
    |> Router.call([])
  end
end
