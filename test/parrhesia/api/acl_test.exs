defmodule Parrhesia.API.ACLTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.API.ACL
  alias Parrhesia.API.RequestContext

  setup do
    previous_acl = Application.get_env(:parrhesia, :acl, [])

    Application.put_env(
      :parrhesia,
      :acl,
      protected_filters: [%{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}]
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :acl, previous_acl)
    end)

    :ok
  end

  test "grant/list/revoke round-trips rules" do
    rule = %{
      principal_type: :pubkey,
      principal: String.duplicate("a", 64),
      capability: :sync_read,
      match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
    }

    assert :ok = ACL.grant(rule)
    assert {:ok, [stored_rule]} = ACL.list(principal: rule.principal, capability: :sync_read)
    assert stored_rule.match == rule.match

    assert :ok = ACL.revoke(%{id: stored_rule.id})
    assert {:ok, []} = ACL.list(principal: rule.principal)
  end

  test "check/3 requires auth and matching grant for protected sync reads" do
    filter = %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
    authenticated_pubkey = String.duplicate("b", 64)

    assert {:error, :auth_required} =
             ACL.check(:sync_read, filter, context: %RequestContext{caller: :websocket})

    assert {:error, :sync_read_not_allowed} =
             ACL.check(:sync_read, filter,
               context: %RequestContext{
                 caller: :websocket,
                 authenticated_pubkeys: MapSet.new([authenticated_pubkey])
               }
             )

    assert :ok =
             ACL.grant(%{
               principal_type: :pubkey,
               principal: authenticated_pubkey,
               capability: :sync_read,
               match: filter
             })

    assert :ok =
             ACL.check(:sync_read, filter,
               context: %RequestContext{
                 caller: :websocket,
                 authenticated_pubkeys: MapSet.new([authenticated_pubkey])
               }
             )
  end

  test "check/3 rejects broader filters than the granted rule" do
    principal = String.duplicate("c", 64)

    assert :ok =
             ACL.grant(%{
               principal_type: :pubkey,
               principal: principal,
               capability: :sync_read,
               match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
             })

    assert {:error, :sync_read_not_allowed} =
             ACL.check(:sync_read, %{"kinds" => [5000]},
               context: %RequestContext{
                 caller: :websocket,
                 authenticated_pubkeys: MapSet.new([principal])
               }
             )
  end

  test "check/3 bypasses protected sync ACL for local callers" do
    protected_filter = %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}

    assert :ok =
             ACL.check(:sync_read, %{"ids" => [String.duplicate("d", 64)]},
               context: %RequestContext{caller: :local}
             )

    assert :ok =
             ACL.check(
               :sync_write,
               %{
                 "id" => String.duplicate("e", 64),
                 "kind" => 5000,
                 "tags" => [["r", "tribes.accounts.user"]]
               },
               context: %RequestContext{caller: :local}
             )

    assert {:error, :sync_read_not_allowed} =
             ACL.check(:sync_read, protected_filter,
               context: %RequestContext{
                 caller: :websocket,
                 authenticated_pubkeys: MapSet.new([String.duplicate("f", 64)])
               }
             )
  end
end
