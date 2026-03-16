defmodule Parrhesia.Storage.Adapters.Postgres.AdapterContractTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Adapters.Postgres.ACL
  alias Parrhesia.Storage.Adapters.Postgres.Admin
  alias Parrhesia.Storage.Adapters.Postgres.Groups
  alias Parrhesia.Storage.Adapters.Postgres.Moderation

  setup_all do
    if is_nil(Process.whereis(Repo)) do
      start_supervised!(Repo)
    end

    Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "moderation adapter persists pubkey/event/ip block state" do
    pubkey = String.duplicate("a", 64)
    event_id = String.duplicate("b", 64)

    assert {:ok, false} = Moderation.pubkey_banned?(%{}, pubkey)
    assert :ok = Moderation.ban_pubkey(%{}, pubkey)
    assert :ok = Moderation.ban_pubkey(%{}, pubkey)
    assert {:ok, true} = Moderation.pubkey_banned?(%{}, pubkey)
    assert :ok = Moderation.unban_pubkey(%{}, pubkey)
    assert {:ok, false} = Moderation.pubkey_banned?(%{}, pubkey)

    assert {:ok, false} = Moderation.pubkey_allowed?(%{}, pubkey)
    assert {:ok, false} = Moderation.has_allowed_pubkeys?(%{})
    assert :ok = Moderation.allow_pubkey(%{}, pubkey)
    assert {:ok, true} = Moderation.pubkey_allowed?(%{}, pubkey)
    assert {:ok, true} = Moderation.has_allowed_pubkeys?(%{})
    assert :ok = Moderation.disallow_pubkey(%{}, pubkey)
    assert {:ok, false} = Moderation.pubkey_allowed?(%{}, pubkey)
    assert {:ok, false} = Moderation.has_allowed_pubkeys?(%{})

    assert {:ok, false} = Moderation.event_banned?(%{}, event_id)
    assert :ok = Moderation.ban_event(%{}, event_id)
    assert {:ok, true} = Moderation.event_banned?(%{}, event_id)
    assert :ok = Moderation.unban_event(%{}, event_id)
    assert {:ok, false} = Moderation.event_banned?(%{}, event_id)

    assert {:ok, false} = Moderation.ip_blocked?(%{}, "127.0.0.1")
    assert :ok = Moderation.block_ip(%{}, "127.0.0.1")
    assert {:ok, true} = Moderation.ip_blocked?(%{}, "127.0.0.1")
    assert :ok = Moderation.unblock_ip(%{}, "127.0.0.1")
    assert {:ok, false} = Moderation.ip_blocked?(%{}, "127.0.0.1")
  end

  test "groups adapter upserts and lists memberships and roles" do
    group_id = "group-alpha"
    member_pubkey = String.duplicate("c", 64)

    assert {:ok, membership} =
             Groups.put_membership(%{}, %{
               group_id: group_id,
               pubkey: member_pubkey,
               role: "member",
               metadata: %{"joined_via" => "invite"}
             })

    assert membership.group_id == group_id
    assert membership.pubkey == member_pubkey
    assert membership.role == "member"

    assert {:ok, fetched_membership} = Groups.get_membership(%{}, group_id, member_pubkey)
    assert fetched_membership.metadata == %{"joined_via" => "invite"}

    assert {:ok, updated_membership} =
             Groups.put_membership(%{}, %{
               "group_id" => group_id,
               "pubkey" => member_pubkey,
               "role" => "admin",
               "metadata" => %{"joined_via" => "promoted"}
             })

    assert updated_membership.role == "admin"

    assert {:ok, memberships} = Groups.list_memberships(%{}, group_id)
    assert Enum.map(memberships, &{&1.pubkey, &1.role}) == [{member_pubkey, "admin"}]

    assert {:ok, role} =
             Groups.put_role(%{}, %{
               group_id: group_id,
               pubkey: member_pubkey,
               role: "moderator",
               metadata: %{"scope" => "global"}
             })

    assert role.role == "moderator"

    assert {:ok, roles} = Groups.list_roles(%{}, group_id, member_pubkey)
    assert Enum.map(roles, & &1.role) == ["moderator"]

    assert :ok = Groups.delete_role(%{}, group_id, member_pubkey, "moderator")
    assert {:ok, []} = Groups.list_roles(%{}, group_id, member_pubkey)

    assert :ok = Groups.delete_membership(%{}, group_id, member_pubkey)
    assert {:ok, nil} = Groups.get_membership(%{}, group_id, member_pubkey)
  end

  test "acl adapter upserts, lists, and deletes rules" do
    principal = String.duplicate("f", 64)

    rule = %{
      principal_type: :pubkey,
      principal: principal,
      capability: :sync_read,
      match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
    }

    assert {:ok, stored_rule} = ACL.put_rule(%{}, rule)
    assert stored_rule.principal == principal

    assert {:ok, [listed_rule]} =
             ACL.list_rules(%{}, principal_type: :pubkey, capability: :sync_read)

    assert listed_rule.id == stored_rule.id

    assert :ok = ACL.delete_rule(%{}, %{id: stored_rule.id})
    assert {:ok, []} = ACL.list_rules(%{}, principal: principal)
  end

  test "admin adapter appends and filters audit logs" do
    actor_pubkey = String.duplicate("d", 64)

    assert :ok =
             Admin.append_audit_log(%{}, %{
               method: "ban_pubkey",
               actor_pubkey: actor_pubkey,
               params: %{"pubkey" => String.duplicate("e", 64)},
               result: %{"ok" => true}
             })

    assert :ok =
             Admin.append_audit_log(%{}, %{
               method: "stats",
               params: %{"window" => "24h"}
             })

    assert {:ok, logs} = Admin.list_audit_logs(%{}, limit: 10)
    assert length(logs) == 2

    assert {:ok, actor_logs} = Admin.list_audit_logs(%{}, actor_pubkey: actor_pubkey)
    assert Enum.map(actor_logs, & &1.method) == ["ban_pubkey"]

    assert {:ok, stats_logs} = Admin.list_audit_logs(%{}, method: :stats)
    assert Enum.map(stats_logs, & &1.method) == ["stats"]

    assert {:ok, %{"status" => "ok"}} = Admin.execute(%{}, :ping, %{})

    assert {:ok,
            %{
              "events" => _events,
              "banned_pubkeys" => _banned,
              "allowed_pubkeys" => _allowed,
              "acl_rules" => _acl_rules,
              "blocked_ips" => _ips
            }} =
             Admin.execute(%{}, :stats, %{})

    assert {:ok, %{"methods" => methods}} = Admin.execute(%{}, :supportedmethods, %{})
    assert "allow_pubkey" in methods

    assert {:error, {:unsupported_method, "status"}} = Admin.execute(%{}, :status, %{})
  end
end
