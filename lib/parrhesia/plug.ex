defmodule Parrhesia.Plug do
  @moduledoc """
  Official Plug interface for mounting Parrhesia HTTP/WebSocket ingress in a host app.

  This plug serves the same route surface as the built-in listener endpoint:

  - `GET /health`
  - `GET /ready`
  - `GET /relay` (NIP-11 + websocket transport)
  - `POST /management`
  - `GET /metrics`

  ## Options

    * `:listener` - listener configuration used to authorize and serve requests.
      Supported values:
      * an atom listener id from `config :parrhesia, :listeners` (for example `:public`)
      * a listener config map/keyword list (same schema as `:listeners` entries)

  When a host app owns the HTTPS edge, a common pattern is:

      config :parrhesia, :listeners, %{}

  and mount `Parrhesia.Plug` with an explicit `:listener` map.
  """

  @behaviour Plug

  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.Router

  @type listener_option :: atom() | map() | keyword()
  @type option :: {:listener, listener_option()}

  @spec init([option()]) :: keyword()
  @impl Plug
  def init(opts) do
    opts = Keyword.validate!(opts, listener: :public)
    listener = opts |> Keyword.fetch!(:listener) |> resolve_listener!()
    [listener: listener]
  end

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl Plug
  def call(conn, opts) do
    conn
    |> Listener.put_conn(opts)
    |> Router.call([])
  end

  defp resolve_listener!(listener_id) when is_atom(listener_id) do
    listeners = Application.get_env(:parrhesia, :listeners, %{})

    case lookup_listener_by_id(listeners, listener_id) do
      nil ->
        raise ArgumentError,
              "listener #{inspect(listener_id)} not found in config :parrhesia, :listeners; " <>
                "configure it there or pass :listener as a map"

      listener ->
        Listener.from_opts(listener: listener)
    end
  end

  defp resolve_listener!(listener) when is_map(listener) do
    Listener.from_opts(listener: listener)
  end

  defp resolve_listener!(listener) when is_list(listener) do
    if Keyword.keyword?(listener) do
      Listener.from_opts(listener: Map.new(listener))
    else
      raise ArgumentError,
            ":listener keyword list must be a valid keyword configuration"
    end
  end

  defp resolve_listener!(other) do
    raise ArgumentError,
          ":listener must be an atom id, map, or keyword list, got: #{inspect(other)}"
  end

  defp lookup_listener_by_id(listeners, listener_id) when is_map(listeners) do
    case Map.fetch(listeners, listener_id) do
      {:ok, listener} when is_map(listener) ->
        Map.put_new(listener, :id, listener_id)

      {:ok, listener} when is_list(listener) ->
        listener |> Map.new() |> Map.put_new(:id, listener_id)

      _other ->
        nil
    end
  end

  defp lookup_listener_by_id(listeners, listener_id) when is_list(listeners) do
    case Enum.find(listeners, fn
           {id, _listener} -> id == listener_id
           _other -> false
         end) do
      {^listener_id, listener} when is_map(listener) ->
        Map.put_new(listener, :id, listener_id)

      {^listener_id, listener} when is_list(listener) ->
        listener |> Map.new() |> Map.put_new(:id, listener_id)

      _other ->
        nil
    end
  end

  defp lookup_listener_by_id(_listeners, _listener_id), do: nil
end
