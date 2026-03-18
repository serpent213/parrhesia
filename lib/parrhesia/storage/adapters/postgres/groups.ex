defmodule Parrhesia.Storage.Adapters.Postgres.Groups do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Groups`.
  """

  import Ecto.Query

  alias Parrhesia.PostgresRepos
  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Groups

  @impl true
  def put_membership(_context, membership) when is_map(membership) do
    with {:ok, group_id} <- fetch_required_string(membership, :group_id),
         {:ok, pubkey} <- fetch_required_pubkey(membership),
         {:ok, role} <- fetch_required_string(membership, :role),
         {:ok, metadata} <- fetch_map(membership, :metadata) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        ensure_group_exists!(group_id, now)
        upsert_group_membership!(group_id, pubkey, role, metadata, now)
        to_membership_map(group_id, pubkey, role, metadata)
      end)
      |> unwrap_transaction_result()
    end
  end

  def put_membership(_context, _membership), do: {:error, :invalid_membership}

  @impl true
  def get_membership(_context, group_id, pubkey) do
    with {:ok, normalized_group_id} <- normalize_group_id(group_id),
         {:ok, normalized_pubkey} <- normalize_pubkey(pubkey) do
      query =
        from(membership in "group_memberships",
          where:
            membership.group_id == ^normalized_group_id and
              membership.pubkey == ^normalized_pubkey,
          select: %{
            group_id: membership.group_id,
            pubkey: membership.pubkey,
            role: membership.role,
            metadata: membership.metadata
          },
          limit: 1
        )

      repo = read_repo()

      case repo.one(query) do
        nil ->
          {:ok, nil}

        membership ->
          {:ok,
           to_membership_map(
             membership.group_id,
             membership.pubkey,
             membership.role,
             membership.metadata
           )}
      end
    end
  end

  @impl true
  def delete_membership(_context, group_id, pubkey) do
    with {:ok, normalized_group_id} <- normalize_group_id(group_id),
         {:ok, normalized_pubkey} <- normalize_pubkey(pubkey) do
      query =
        from(membership in "group_memberships",
          where:
            membership.group_id == ^normalized_group_id and
              membership.pubkey == ^normalized_pubkey
        )

      {_deleted, _result} = Repo.delete_all(query)
      :ok
    end
  end

  @impl true
  def list_memberships(_context, group_id) do
    with {:ok, normalized_group_id} <- normalize_group_id(group_id) do
      query =
        from(membership in "group_memberships",
          where: membership.group_id == ^normalized_group_id,
          order_by: [asc: membership.role, asc: membership.pubkey],
          select: %{
            group_id: membership.group_id,
            pubkey: membership.pubkey,
            role: membership.role,
            metadata: membership.metadata
          }
        )

      memberships =
        read_repo()
        |> then(fn repo -> repo.all(query) end)
        |> Enum.map(fn membership ->
          to_membership_map(
            membership.group_id,
            membership.pubkey,
            membership.role,
            membership.metadata
          )
        end)

      {:ok, memberships}
    end
  end

  @impl true
  def put_role(_context, role) when is_map(role) do
    with {:ok, group_id} <- fetch_required_string(role, :group_id),
         {:ok, pubkey} <- fetch_required_pubkey(role),
         {:ok, role_name} <- fetch_required_string(role, :role),
         {:ok, metadata} <- fetch_map(role, :metadata) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        ensure_group_exists!(group_id, now)
        upsert_group_role!(group_id, pubkey, role_name, metadata, now)
        to_role_map(group_id, pubkey, role_name, metadata)
      end)
      |> unwrap_transaction_result()
    end
  end

  def put_role(_context, _role), do: {:error, :invalid_role}

  @impl true
  def delete_role(_context, group_id, pubkey, role_name) do
    with {:ok, normalized_group_id} <- normalize_group_id(group_id),
         {:ok, normalized_pubkey} <- normalize_pubkey(pubkey),
         {:ok, normalized_role_name} <- normalize_role(role_name) do
      query =
        from(role in "group_roles",
          where:
            role.group_id == ^normalized_group_id and
              role.pubkey == ^normalized_pubkey and
              role.role == ^normalized_role_name
        )

      {_deleted, _result} = Repo.delete_all(query)
      :ok
    end
  end

  @impl true
  def list_roles(_context, group_id, pubkey) do
    with {:ok, normalized_group_id} <- normalize_group_id(group_id),
         {:ok, normalized_pubkey} <- normalize_pubkey(pubkey) do
      query =
        from(role in "group_roles",
          where: role.group_id == ^normalized_group_id and role.pubkey == ^normalized_pubkey,
          order_by: [asc: role.role],
          select: %{
            group_id: role.group_id,
            pubkey: role.pubkey,
            role: role.role,
            metadata: role.metadata
          }
        )

      roles =
        read_repo()
        |> then(fn repo -> repo.all(query) end)
        |> Enum.map(fn role ->
          to_role_map(role.group_id, role.pubkey, role.role, role.metadata)
        end)

      {:ok, roles}
    end
  end

  defp ensure_group_exists!(group_id, now) do
    {inserted, _result} =
      Repo.insert_all(
        "relay_groups",
        [
          %{
            group_id: group_id,
            metadata: %{},
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:group_id]
      )

    ensure_single_upsert_row!(inserted, :group_upsert_failed)
  end

  defp upsert_group_membership!(group_id, pubkey, role, metadata, now) do
    {inserted, _result} =
      Repo.insert_all(
        "group_memberships",
        [
          %{
            group_id: group_id,
            pubkey: pubkey,
            role: role,
            metadata: metadata,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [set: [role: role, metadata: metadata, updated_at: now]],
        conflict_target: [:group_id, :pubkey]
      )

    ensure_single_upsert_row!(inserted, :membership_upsert_failed)
  end

  defp upsert_group_role!(group_id, pubkey, role_name, metadata, now) do
    {inserted, _result} =
      Repo.insert_all(
        "group_roles",
        [
          %{
            group_id: group_id,
            pubkey: pubkey,
            role: role_name,
            metadata: metadata,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [set: [metadata: metadata, updated_at: now]],
        conflict_target: [:group_id, :pubkey, :role]
      )

    ensure_single_upsert_row!(inserted, :role_upsert_failed)
  end

  defp ensure_single_upsert_row!(inserted, _failure_reason) when inserted <= 1, do: :ok

  defp ensure_single_upsert_row!(_inserted, failure_reason) do
    Repo.rollback(failure_reason)
  end

  defp unwrap_transaction_result({:ok, result}), do: {:ok, result}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
  defp read_repo, do: PostgresRepos.read()

  defp fetch_required_string(map, key) do
    map
    |> fetch_value(key)
    |> normalize_non_empty_string(invalid_key_reason(key))
  end

  defp fetch_required_pubkey(map) do
    map
    |> fetch_value(:pubkey)
    |> normalize_pubkey()
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _value -> {:error, invalid_key_reason(key)}
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_group_id(group_id), do: normalize_non_empty_string(group_id, :invalid_group_id)
  defp normalize_role(role_name), do: normalize_non_empty_string(role_name, :invalid_role)

  defp normalize_non_empty_string(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_non_empty_string(_value, reason), do: {:error, reason}

  defp normalize_pubkey(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}

  defp normalize_pubkey(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, pubkey} -> {:ok, pubkey}
      :error -> {:error, :invalid_pubkey}
    end
  end

  defp normalize_pubkey(_value), do: {:error, :invalid_pubkey}

  defp invalid_key_reason(:group_id), do: :invalid_group_id
  defp invalid_key_reason(:pubkey), do: :invalid_pubkey
  defp invalid_key_reason(:role), do: :invalid_role
  defp invalid_key_reason(:metadata), do: :invalid_metadata

  defp to_membership_map(group_id, pubkey, role, metadata) do
    %{
      group_id: group_id,
      pubkey: Base.encode16(pubkey, case: :lower),
      role: role,
      metadata: metadata
    }
  end

  defp to_role_map(group_id, pubkey, role_name, metadata) do
    %{
      group_id: group_id,
      pubkey: Base.encode16(pubkey, case: :lower),
      role: role_name,
      metadata: metadata
    }
  end
end
