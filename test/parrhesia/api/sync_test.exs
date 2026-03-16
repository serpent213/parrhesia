defmodule Parrhesia.API.SyncTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.API.Admin
  alias Parrhesia.API.Sync
  alias Parrhesia.API.Sync.Manager
  alias Parrhesia.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "put_server stores normalized config and persists it across restart" do
    {manager, path, pid} = start_sync_manager()

    assert {:ok, stored_server} = Sync.put_server(valid_server(), manager: manager)
    assert stored_server.id == "tribes-primary"
    assert stored_server.mode == :req_stream
    assert stored_server.auth.type == :nip42
    assert stored_server.tls.mode == :required
    assert stored_server.tls.hostname == "relay-a.example"
    assert stored_server.runtime.state == :running
    assert File.exists?(path)

    assert {:ok, fetched_server} = Sync.get_server("tribes-primary", manager: manager)
    assert fetched_server == stored_server

    assert {:ok, [listed_server]} = Sync.list_servers(manager: manager)
    assert listed_server.id == "tribes-primary"

    monitor_ref = Process.monitor(pid)
    assert :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
    assert {:ok, persisted_server} = wait_for_server(manager, "tribes-primary")
    assert persisted_server.id == "tribes-primary"
    assert persisted_server.tls.hostname == "relay-a.example"
    assert persisted_server.runtime.state == :running
  end

  test "start_server stop_server and sync_now update runtime stats" do
    {manager, _path, _pid} = start_sync_manager()

    disabled_server = valid_server(%{"id" => "tribes-disabled", "enabled?" => false})
    assert {:ok, stored_server} = Sync.put_server(disabled_server, manager: manager)
    assert stored_server.runtime.state == :stopped

    assert :ok = Sync.start_server("tribes-disabled", manager: manager)

    assert {:ok, started_server} = Sync.get_server("tribes-disabled", manager: manager)
    assert started_server.runtime.state == :running

    assert :ok = Sync.sync_now("tribes-disabled", manager: manager)

    assert {:ok, stats} = Sync.server_stats("tribes-disabled", manager: manager)
    assert stats["server_id"] == "tribes-disabled"
    assert stats["state"] == "running"
    assert stats["query_runs"] == 1
    assert is_binary(stats["last_sync_started_at"])
    assert is_binary(stats["last_sync_completed_at"])

    assert :ok = Sync.stop_server("tribes-disabled", manager: manager)

    assert {:ok, stopped_server} = Sync.get_server("tribes-disabled", manager: manager)
    assert stopped_server.runtime.state == :stopped
    assert is_binary(stopped_server.runtime.last_disconnected_at)

    assert {:ok, sync_stats} = Sync.sync_stats(manager: manager)
    assert sync_stats["servers_total"] == 1
    assert sync_stats["servers_enabled"] == 0
    assert sync_stats["servers_running"] == 0
    assert sync_stats["query_runs"] == 1

    assert {:ok, sync_health} = Sync.sync_health(manager: manager)

    assert sync_health == %{
             "status" => "ok",
             "servers_total" => 1,
             "servers_connected" => 0,
             "servers_failing" => []
           }
  end

  test "put_server rejects invalid sync server shapes" do
    {manager, _path, _pid} = start_sync_manager()

    assert {:error, :invalid_url} =
             Sync.put_server(Map.put(valid_server(), "url", "https://relay-a.example"),
               manager: manager
             )

    assert {:error, :empty_filters} =
             Sync.put_server(Map.put(valid_server(), "filters", []), manager: manager)

    assert {:error, :invalid_tls_pins} =
             Sync.put_server(
               put_in(valid_server()["tls"]["pins"], []),
               manager: manager
             )
  end

  test "admin executes sync methods against an injected sync manager" do
    {manager, _path, _pid} = start_sync_manager()

    assert {:ok, created_server} =
             Admin.execute("sync_put_server", valid_server(%{"id" => "tribes-admin"}),
               manager: manager
             )

    assert created_server.id == "tribes-admin"

    assert {:ok, listed_servers} = Admin.execute("sync_list_servers", %{}, manager: manager)
    assert Enum.any?(listed_servers, &(&1.id == "tribes-admin"))

    assert {:ok, %{"ok" => true}} =
             Admin.execute("sync_sync_now", %{"id" => "tribes-admin"}, manager: manager)

    assert {:ok, sync_stats} = Admin.stats(manager: manager)
    assert sync_stats["sync"]["servers_total"] == 1
    assert sync_stats["sync"]["query_runs"] == 1

    assert {:ok, health} = Admin.health(manager: manager)
    assert health["status"] == "ok"
    assert health["sync"]["servers_total"] == 1
  end

  defp start_sync_manager do
    path = unique_sync_path()
    manager = {:global, {:sync_manager, System.unique_integer([:positive, :monotonic])}}
    pid = start_supervised!({Manager, name: manager, path: path, start_workers?: false})

    {manager, path, pid}
  end

  defp valid_server(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "tribes-primary",
        "url" => "wss://relay-a.example/relay",
        "enabled?" => true,
        "auth_pubkey" => String.duplicate("a", 64),
        "filters" => [
          %{
            "kinds" => [5000],
            "#r" => ["tribes.accounts.user"]
          }
        ],
        "tls" => %{
          "pins" => [
            %{
              "type" => "spki_sha256",
              "value" => "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            }
          ]
        },
        "metadata" => %{"cluster" => "primary"}
      },
      overrides
    )
  end

  defp unique_sync_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_sync_#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn ->
      _ = File.rm(path)
    end)

    path
  end

  defp wait_for_server(manager, server_id, attempts \\ 10)

  defp wait_for_server(_manager, _server_id, 0), do: :error

  defp wait_for_server(manager, server_id, attempts) do
    result =
      try do
        Sync.get_server(server_id, manager: manager)
      catch
        :exit, _reason -> {:error, :noproc}
      end

    case result do
      {:ok, server} ->
        {:ok, server}

      :error ->
        receive do
        after
          10 -> wait_for_server(manager, server_id, attempts - 1)
        end

      {:error, :noproc} ->
        receive do
        after
          10 -> wait_for_server(manager, server_id, attempts - 1)
        end

      {:error, {:noproc, _details}} ->
        receive do
        after
          10 -> wait_for_server(manager, server_id, attempts - 1)
        end
    end
  end
end
