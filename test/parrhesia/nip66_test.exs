defmodule Parrhesia.Nip66Test do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.API.Events
  alias Parrhesia.API.RequestContext
  alias Parrhesia.NIP66
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.RelayInfo

  setup do
    previous_nip66 = Application.get_env(:parrhesia, :nip66)
    previous_relay_url = Application.get_env(:parrhesia, :relay_url)

    on_exit(fn ->
      Application.put_env(:parrhesia, :nip66, previous_nip66)
      Application.put_env(:parrhesia, :relay_url, previous_relay_url)
    end)

    :ok
  end

  test "publish_snapshot stores monitor and discovery events for the configured relay" do
    identity_path = unique_identity_path()
    relay_url = "ws://127.0.0.1:4413/relay"

    Application.put_env(:parrhesia, :relay_url, relay_url)

    Application.put_env(:parrhesia, :nip66,
      enabled: true,
      publish_interval_seconds: 600,
      publish_monitor_announcement?: true,
      timeout_ms: 2_500,
      checks: [:open, :read, :nip11],
      geohash: "u33dc1",
      targets: [
        %{
          listener: :public,
          relay_url: relay_url,
          topics: ["marmot"],
          relay_type: "PublicInbox"
        }
      ]
    )

    probe_fun = fn _target, _probe_opts, _publish_opts ->
      {:ok,
       %{
         checks: [:open, :read, :nip11],
         metrics: %{rtt_open_ms: 12, rtt_read_ms: 34},
         relay_info: nil,
         relay_info_body: nil
       }}
    end

    assert {:ok, [monitor_event, discovery_event]} =
             NIP66.publish_snapshot(
               path: identity_path,
               now: 1_700_000_000,
               context: %RequestContext{},
               probe_fun: probe_fun
             )

    assert monitor_event["kind"] == 10_166
    assert discovery_event["kind"] == 30_166
    assert :ok = EventValidator.validate(monitor_event)
    assert :ok = EventValidator.validate(discovery_event)

    assert {:ok, stored_events} =
             Events.query(
               [%{"ids" => [monitor_event["id"], discovery_event["id"]]}],
               context: %RequestContext{}
             )

    assert Enum.sort(Enum.map(stored_events, & &1["kind"])) == [10_166, 30_166]

    assert Enum.any?(discovery_event["tags"], &(&1 == ["d", relay_url]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["n", "clearnet"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["T", "PublicInbox"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["t", "marmot"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["rtt-open", "12"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["rtt-read", "34"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["N", "66"]))
    assert Enum.any?(discovery_event["tags"], &(&1 == ["R", "!payment"]))

    relay_info = JSON.decode!(discovery_event["content"])
    assert relay_info["self"] == discovery_event["pubkey"]
    assert 66 in relay_info["supported_nips"]
  end

  test "relay info only advertises NIP-66 when the publisher is enabled" do
    listener = Listener.from_opts(listener: %{id: :public, bind: %{port: 4413}})

    Application.put_env(:parrhesia, :nip66, enabled: false)
    refute 66 in RelayInfo.document(listener)["supported_nips"]

    Application.put_env(:parrhesia, :nip66, enabled: true)
    assert 66 in RelayInfo.document(listener)["supported_nips"]
  end

  defp unique_identity_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_nip66_identity_#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn ->
      _ = File.rm(path)
    end)

    path
  end
end
