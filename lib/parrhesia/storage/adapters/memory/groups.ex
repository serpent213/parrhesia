defmodule Parrhesia.Storage.Adapters.Memory.Groups do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.Groups`.
  """

  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.Groups

  @impl true
  def put_membership(_context, membership) do
    group_id = fetch!(membership, :group_id)
    pubkey = fetch!(membership, :pubkey)

    normalized = %{
      group_id: group_id,
      pubkey: pubkey,
      role: fetch!(membership, :role),
      metadata: Map.get(membership, :metadata, %{})
    }

    Store.update(fn state -> put_in(state.groups[{group_id, pubkey}], normalized) end)
    {:ok, normalized}
  end

  @impl true
  def get_membership(_context, group_id, pubkey) do
    {:ok, Store.get(fn state -> Map.get(state.groups, {group_id, pubkey}) end)}
  end

  @impl true
  def delete_membership(_context, group_id, pubkey) do
    Store.update(fn state -> update_in(state.groups, &Map.delete(&1, {group_id, pubkey})) end)
    :ok
  end

  @impl true
  def list_memberships(_context, group_id) do
    memberships =
      Store.get(fn state ->
        state.groups
        |> Map.values()
        |> Enum.filter(fn membership -> membership.group_id == group_id end)
      end)

    {:ok, memberships}
  end

  @impl true
  def put_role(_context, role) do
    group_id = fetch!(role, :group_id)
    pubkey = fetch!(role, :pubkey)
    role_name = fetch!(role, :role)

    normalized = %{
      group_id: group_id,
      pubkey: pubkey,
      role: role_name,
      metadata: Map.get(role, :metadata, %{})
    }

    Store.update(fn state -> put_in(state.roles[{group_id, pubkey, role_name}], normalized) end)
    {:ok, normalized}
  end

  @impl true
  def delete_role(_context, group_id, pubkey, role_name) do
    Store.update(fn state ->
      update_in(state.roles, &Map.delete(&1, {group_id, pubkey, role_name}))
    end)

    :ok
  end

  @impl true
  def list_roles(_context, group_id, pubkey) do
    roles =
      Store.get(fn state ->
        state.roles
        |> Map.values()
        |> Enum.filter(fn role -> role.group_id == group_id and role.pubkey == pubkey end)
      end)

    {:ok, roles}
  end

  defp fetch!(map, key) do
    Map.get(map, key) || Map.fetch!(map, Atom.to_string(key))
  end
end
