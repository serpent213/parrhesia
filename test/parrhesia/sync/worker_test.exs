defmodule Parrhesia.Sync.WorkerTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.API.ACL
  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.API.Sync
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Sync.Supervisor
  alias Parrhesia.TestSupport.SyncFakeRelay.Plug
  alias Parrhesia.TestSupport.SyncFakeRelay.Server

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "req_stream worker verifies remote identity, authenticates, syncs catch-up, streams live, and sync_now reruns catch-up" do
    {:ok, %{pubkey: local_pubkey}} = Identity.ensure()
    remote_pubkey = String.duplicate("b", 64)
    initial_event = valid_sync_event("initial-sync", 1_762_000_000)
    live_event = valid_sync_event("live-sync", 1_762_000_100)

    relay_server =
      start_supervised!(
        {Server,
         name: unique_name("FakeRelayServer"),
         pubkey: remote_pubkey,
         expected_client_pubkey: local_pubkey,
         initial_events: [initial_event]}
      )

    port = free_port()

    start_supervised!(
      {Bandit, plug: {Plug, server: relay_server}, ip: {127, 0, 0, 1}, port: port}
    )

    relay_url = "ws://127.0.0.1:#{port}/relay"
    wait_for_relay(relay_url, remote_pubkey)

    assert :ok =
             ACL.grant(%{
               principal_type: :pubkey,
               principal: remote_pubkey,
               capability: :sync_write,
               match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
             })

    assert :ok =
             ACL.grant(%{
               principal_type: :pubkey,
               principal: remote_pubkey,
               capability: :sync_read,
               match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
             })

    {manager_name, _supervisor_name} = start_sync_runtime()

    assert {:ok, _server} =
             Sync.put_server(
               %{
                 "id" => "fake-relay",
                 "url" => relay_url,
                 "enabled?" => true,
                 "auth_pubkey" => remote_pubkey,
                 "filters" => [%{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}],
                 "tls" => %{"mode" => "disabled", "pins" => []}
               },
               manager: manager_name
             )

    assert_event_synced(initial_event, remote_pubkey)

    assert :ok = Server.publish_live_event(relay_server, live_event)
    assert_event_synced(live_event, remote_pubkey)

    assert {:ok, stats_before_sync_now} = Sync.sync_stats(manager: manager_name)
    assert stats_before_sync_now["events_accepted"] >= 2

    assert :ok = Sync.sync_now("fake-relay", manager: manager_name)

    assert_eventually(fn ->
      case Sync.sync_stats(manager: manager_name) do
        {:ok, stats} -> stats["query_runs"] >= 2 and stats["subscription_restarts"] >= 1
        _other -> false
      end
    end)

    assert {:ok, health} = Sync.sync_health(manager: manager_name)
    assert health["status"] == "ok"
    assert health["servers_connected"] == 1
  end

  test "worker marks remote identity mismatches as failing health" do
    {:ok, %{pubkey: local_pubkey}} = Identity.ensure()

    relay_server =
      start_supervised!(
        {Server,
         name: unique_name("MismatchRelayServer"),
         pubkey: String.duplicate("d", 64),
         expected_client_pubkey: local_pubkey,
         initial_events: []}
      )

    port = free_port()

    start_supervised!(
      {Bandit, plug: {Plug, server: relay_server}, ip: {127, 0, 0, 1}, port: port}
    )

    relay_url = "ws://127.0.0.1:#{port}/relay"
    wait_for_relay(relay_url, String.duplicate("d", 64))

    {manager_name, _supervisor_name} = start_sync_runtime()

    assert {:ok, _server} =
             Sync.put_server(
               %{
                 "id" => "mismatch-relay",
                 "url" => relay_url,
                 "enabled?" => true,
                 "auth_pubkey" => String.duplicate("e", 64),
                 "filters" => [%{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}],
                 "tls" => %{"mode" => "disabled", "pins" => []}
               },
               manager: manager_name
             )

    assert_eventually(fn ->
      case Sync.sync_health(manager: manager_name) do
        {:ok, %{"status" => "degraded", "servers_failing" => servers}} ->
          Enum.any?(
            servers,
            &(&1["id"] == "mismatch-relay" and &1["reason"] == ":remote_identity_mismatch")
          )

        _other ->
          false
      end
    end)
  end

  defp start_sync_runtime do
    manager_name = unique_name("SyncManager")
    worker_registry = unique_name("SyncRegistry")
    worker_supervisor = unique_name("SyncWorkerSupervisor")
    supervisor_name = unique_name("SyncSupervisor")

    start_supervised!(
      {Supervisor,
       name: supervisor_name,
       manager: manager_name,
       worker_registry: worker_registry,
       worker_supervisor: worker_supervisor,
       path: unique_sync_path(),
       start_workers?: true}
    )

    {manager_name, supervisor_name}
  end

  defp assert_event_synced(event, remote_pubkey) do
    assert_eventually(fn ->
      case Events.query(
             [%{"ids" => [event["id"]]}],
             context: %RequestContext{
               authenticated_pubkeys: MapSet.new([remote_pubkey])
             }
           ) do
        {:ok, [stored_event]} -> stored_event["id"] == event["id"]
        _other -> false
      end
    end)
  end

  defp wait_for_relay(relay_url, expected_pubkey) do
    info_url =
      relay_url
      |> String.replace_prefix("ws://", "http://")
      |> String.replace_prefix("wss://", "https://")

    assert_eventually(fn ->
      with {:ok, %{status: 200, body: body}} <-
             Req.get(
               url: info_url,
               headers: [{"accept", "application/nostr+json"}],
               decode_body: false
             ),
           {:ok, %{"pubkey" => ^expected_pubkey}} <- JSON.decode(body) do
        true
      else
        _other -> false
      end
    end)
  end

  defp valid_sync_event(content, created_at) do
    base_event = %{
      "pubkey" => String.duplicate("f", 64),
      "created_at" => created_at,
      "kind" => 5000,
      "tags" => [["r", "tribes.accounts.user"]],
      "content" => content,
      "sig" => String.duplicate("0", 128)
    }

    Map.put(base_event, "id", EventValidator.compute_id(base_event))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_sync_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_sync_runtime_#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn ->
      _ = File.rm(path)
    end)

    path
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      receive do
      after
        50 -> assert_eventually(fun, attempts - 1)
      end
    end
  end
end
