defmodule Parrhesia.Tasks.Nip66PublisherTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: :shared

  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Tasks.Nip66Publisher

  test "publishes a NIP-66 snapshot when ticked" do
    path =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_nip66_worker_#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn ->
      _ = File.rm(path)
    end)

    probe_fun = fn _target, _probe_opts, _publish_opts ->
      {:ok, %{checks: [:open], metrics: %{rtt_open_ms: 8}, relay_info: nil, relay_info_body: nil}}
    end

    worker =
      start_supervised!(
        {Nip66Publisher,
         name: nil,
         interval_ms: 60_000,
         path: path,
         now: 1_700_000_123,
         probe_fun: probe_fun,
         config: [enabled: true, publish_interval_seconds: 600, targets: [%{listener: :public}]]}
      )

    send(worker, :tick)
    _ = :sys.get_state(worker)

    {:ok, %{pubkey: pubkey}} = Identity.get(path: path)

    assert {:ok, events} =
             Events.query(
               [%{"authors" => [pubkey], "kinds" => [10_166, 30_166]}],
               context: %RequestContext{}
             )

    assert Enum.sort(Enum.map(events, & &1["kind"])) == [10_166, 30_166]
  end
end
