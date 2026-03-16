defmodule Parrhesia.Storage.BehaviourContractsTest do
  use ExUnit.Case, async: true

  test "events behavior exposes expected callbacks" do
    assert callback_names(Parrhesia.Storage.Events) ==
             [
               :count,
               :delete_by_request,
               :get_event,
               :purge_expired,
               :put_event,
               :query,
               :query_event_refs,
               :vanish
             ]
  end

  test "moderation behavior exposes expected callbacks" do
    assert callback_names(Parrhesia.Storage.Moderation) ==
             [
               :allow_pubkey,
               :ban_event,
               :ban_pubkey,
               :block_ip,
               :disallow_pubkey,
               :event_banned?,
               :ip_blocked?,
               :pubkey_allowed?,
               :pubkey_banned?,
               :unban_event,
               :unban_pubkey,
               :unblock_ip
             ]
  end

  test "groups behavior exposes expected callbacks" do
    assert callback_names(Parrhesia.Storage.Groups) ==
             [
               :delete_membership,
               :delete_role,
               :get_membership,
               :list_memberships,
               :list_roles,
               :put_membership,
               :put_role
             ]
  end

  test "admin behavior exposes expected callbacks" do
    assert callback_names(Parrhesia.Storage.Admin) ==
             [:append_audit_log, :execute, :list_audit_logs]
  end

  defp callback_names(behavior_module) do
    behavior_module
    |> behaviour_callbacks()
    |> Enum.map(fn {name, _arity} -> name end)
    |> Enum.sort()
  end

  defp behaviour_callbacks(behavior_module), do: behavior_module.behaviour_info(:callbacks)
end
