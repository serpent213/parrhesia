defmodule Parrhesia.NIP43Test do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Groups.Flow
  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.RelayInfo

  test "relay-authored membership snapshots replace the stored access list" do
    first_snapshot =
      signed_relay_event(13_534, [
        ["-"],
        ["member", String.duplicate("a", 64)],
        ["member", String.duplicate("b", 64)]
      ])

    second_snapshot =
      signed_relay_event(13_534, [
        ["-"],
        ["member", String.duplicate("b", 64)]
      ])

    assert {:ok, %{accepted: true}} = Events.publish(first_snapshot, context: %RequestContext{})
    assert {:ok, %{accepted: true}} = Events.publish(second_snapshot, context: %RequestContext{})

    assert {:ok, memberships} = Flow.list_memberships()
    assert Enum.map(memberships, & &1.pubkey) == [String.duplicate("b", 64)]
  end

  test "count includes generated invite responses for kind 28935 filters" do
    assert {:ok, 1} = Events.count([%{"kinds" => [28_935]}], context: %RequestContext{})
  end

  test "relay info only advertises 43 when NIP-43 is enabled" do
    previous_config = Application.get_env(:parrhesia, :nip43, [])

    on_exit(fn ->
      Application.put_env(:parrhesia, :nip43, previous_config)
    end)

    listener = Listener.from_opts(id: :public)

    Application.put_env(:parrhesia, :nip43, enabled: false)
    refute 43 in RelayInfo.document(listener)["supported_nips"]

    Application.put_env(:parrhesia, :nip43, enabled: true, invite_ttl_seconds: 900)
    assert 43 in RelayInfo.document(listener)["supported_nips"]
  end

  defp signed_relay_event(kind, tags) do
    {:ok, event} =
      Identity.sign_event(%{
        "created_at" => System.system_time(:second),
        "kind" => kind,
        "tags" => tags,
        "content" => ""
      })

    event
  end
end
