defmodule Parrhesia.Web.ProxyIpE2ETest do
  use Parrhesia.IntegrationCase, async: false, sandbox: :shared

  alias __MODULE__.TestClient

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:websockex)
    :ok
  end

  setup do
    previous_trusted_proxies = Application.get_env(:parrhesia, :trusted_proxies, [])

    on_exit(fn ->
      Application.put_env(:parrhesia, :trusted_proxies, previous_trusted_proxies)
    end)

    {:ok, port: free_port()}
  end

  test "websocket relay blocks a forwarded client IP from a trusted proxy", %{port: port} do
    Application.put_env(:parrhesia, :trusted_proxies, ["127.0.0.1/32"])
    assert :ok = Parrhesia.Storage.moderation().block_ip(%{}, "203.0.113.10")

    start_supervised!({Bandit, plug: Parrhesia.Web.Router, ip: {127, 0, 0, 1}, port: port})

    wait_for_server(port)

    assert {:error, %WebSockex.RequestError{code: 403, message: "Forbidden"}} =
             TestClient.start_link(relay_url(port), self(),
               extra_headers: [{"x-forwarded-for", "203.0.113.10"}]
             )
  end

  test "websocket relay ignores forwarded client IPs from untrusted proxies", %{port: port} do
    Application.put_env(:parrhesia, :trusted_proxies, [])
    assert :ok = Parrhesia.Storage.moderation().block_ip(%{}, "203.0.113.10")

    start_supervised!({Bandit, plug: Parrhesia.Web.Router, ip: {127, 0, 0, 1}, port: port})

    wait_for_server(port)

    assert {:ok, client} =
             TestClient.start_link(relay_url(port), self(),
               extra_headers: [{"x-forwarded-for", "203.0.113.10"}]
             )

    assert_receive :connected
    Process.exit(client, :normal)
  end

  defp wait_for_server(port) do
    health_url = "http://127.0.0.1:#{port}/health"

    1..50
    |> Enum.reduce_while(:error, fn _attempt, _acc ->
      case Req.get(health_url, receive_timeout: 200, connect_options: [timeout: 200]) do
        {:ok, %{status: 200, body: "ok"}} ->
          {:halt, :ok}

        _other ->
          Process.sleep(50)
          {:cont, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> flunk("server was not ready at #{health_url}")
    end
  end

  defp relay_url(port), do: "ws://127.0.0.1:#{port}/relay"

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defmodule TestClient do
    use WebSockex

    def start_link(url, parent, opts \\ []) do
      WebSockex.start_link(url, __MODULE__, parent, opts)
    end

    @impl true
    def handle_connect(_conn, parent) do
      send(parent, :connected)
      {:ok, parent}
    end

    @impl true
    def handle_disconnect(_disconnect_map, parent) do
      {:ok, parent}
    end
  end
end
