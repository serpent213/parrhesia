defmodule Parrhesia.Storage.Adapters.Postgres.ACL do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.ACL`.
  """

  import Ecto.Query

  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.ACL

  @impl true
  def put_rule(_context, rule) when is_map(rule) do
    with {:ok, normalized_rule} <- normalize_rule(rule) do
      normalized_rule
      |> find_matching_rule()
      |> maybe_insert_rule(normalized_rule)
    end
  end

  def put_rule(_context, _rule), do: {:error, :invalid_acl_rule}

  defp maybe_insert_rule(nil, normalized_rule), do: insert_rule(normalized_rule)
  defp maybe_insert_rule(existing_rule, _normalized_rule), do: {:ok, existing_rule}

  @impl true
  def delete_rule(_context, selector) when is_map(selector) do
    case normalize_delete_selector(selector) do
      {:ok, {:id, id}} ->
        query = from(rule in "acl_rules", where: rule.id == ^id)
        {_deleted, _result} = Repo.delete_all(query)
        :ok

      {:ok, {:exact, rule}} ->
        query =
          from(stored_rule in "acl_rules",
            where:
              stored_rule.principal_type == ^rule.principal_type and
                stored_rule.principal == ^rule.principal and
                stored_rule.capability == ^rule.capability and
                stored_rule.match == ^rule.match
          )

        {_deleted, _result} = Repo.delete_all(query)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_rule(_context, _selector), do: {:error, :invalid_acl_rule}

  @impl true
  def list_rules(_context, opts) when is_list(opts) do
    query =
      from(rule in "acl_rules",
        order_by: [
          asc: rule.principal_type,
          asc: rule.principal,
          asc: rule.capability,
          asc: rule.id
        ],
        select: %{
          id: rule.id,
          principal_type: rule.principal_type,
          principal: rule.principal,
          capability: rule.capability,
          match: rule.match,
          inserted_at: rule.inserted_at
        }
      )
      |> maybe_filter_principal_type(Keyword.get(opts, :principal_type))
      |> maybe_filter_principal(Keyword.get(opts, :principal))
      |> maybe_filter_capability(Keyword.get(opts, :capability))

    {:ok, Enum.map(Repo.all(query), &normalize_persisted_rule/1)}
  end

  def list_rules(_context, _opts), do: {:error, :invalid_opts}

  defp maybe_filter_principal_type(query, nil), do: query

  defp maybe_filter_principal_type(query, principal_type) when is_atom(principal_type) do
    maybe_filter_principal_type(query, Atom.to_string(principal_type))
  end

  defp maybe_filter_principal_type(query, principal_type) when is_binary(principal_type) do
    where(query, [rule], rule.principal_type == ^principal_type)
  end

  defp maybe_filter_principal_type(query, _principal_type), do: query

  defp maybe_filter_principal(query, nil), do: query

  defp maybe_filter_principal(query, principal) when is_binary(principal) do
    case decode_hex_or_binary(principal, 32, :invalid_acl_principal) do
      {:ok, decoded_principal} -> where(query, [rule], rule.principal == ^decoded_principal)
      {:error, _reason} -> where(query, [rule], false)
    end
  end

  defp maybe_filter_principal(query, _principal), do: query

  defp maybe_filter_capability(query, nil), do: query

  defp maybe_filter_capability(query, capability) when is_atom(capability) do
    maybe_filter_capability(query, Atom.to_string(capability))
  end

  defp maybe_filter_capability(query, capability) when is_binary(capability) do
    where(query, [rule], rule.capability == ^capability)
  end

  defp maybe_filter_capability(query, _capability), do: query

  defp find_matching_rule(normalized_rule) do
    query =
      from(stored_rule in "acl_rules",
        where:
          stored_rule.principal_type == ^normalized_rule.principal_type and
            stored_rule.principal == ^normalized_rule.principal and
            stored_rule.capability == ^normalized_rule.capability and
            stored_rule.match == ^normalized_rule.match,
        limit: 1,
        select: %{
          id: stored_rule.id,
          principal_type: stored_rule.principal_type,
          principal: stored_rule.principal,
          capability: stored_rule.capability,
          match: stored_rule.match,
          inserted_at: stored_rule.inserted_at
        }
      )

    case Repo.one(query) do
      nil -> nil
      stored_rule -> normalize_persisted_rule(stored_rule)
    end
  end

  defp insert_rule(normalized_rule) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      principal_type: normalized_rule.principal_type,
      principal: normalized_rule.principal,
      capability: normalized_rule.capability,
      match: normalized_rule.match,
      inserted_at: now
    }

    case Repo.insert_all("acl_rules", [row], returning: [:id, :inserted_at]) do
      {1, [inserted_row]} ->
        {:ok, normalize_persisted_rule(Map.merge(row, Map.new(inserted_row)))}

      _other ->
        {:error, :acl_rule_insert_failed}
    end
  end

  defp normalize_persisted_rule(rule) do
    %{
      id: rule.id,
      principal_type: normalize_principal_type(rule.principal_type),
      principal: Base.encode16(rule.principal, case: :lower),
      capability: normalize_capability(rule.capability),
      match: normalize_match(rule.match),
      inserted_at: rule.inserted_at
    }
  end

  defp normalize_delete_selector(%{"id" => id}), do: normalize_delete_selector(%{id: id})

  defp normalize_delete_selector(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, {:id, id}}

  defp normalize_delete_selector(selector) do
    case normalize_rule(selector) do
      {:ok, normalized_rule} -> {:ok, {:exact, normalized_rule}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_rule(rule) when is_map(rule) do
    with {:ok, principal_type} <- normalize_principal_type_value(fetch(rule, :principal_type)),
         {:ok, principal} <-
           decode_hex_or_binary(fetch(rule, :principal), 32, :invalid_acl_principal),
         {:ok, capability} <- normalize_capability_value(fetch(rule, :capability)),
         {:ok, match} <- normalize_match_value(fetch(rule, :match)) do
      {:ok,
       %{
         principal_type: principal_type,
         principal: principal,
         capability: capability,
         match: match
       }}
    end
  end

  defp normalize_rule(_rule), do: {:error, :invalid_acl_rule}

  defp normalize_principal_type("pubkey"), do: :pubkey
  defp normalize_principal_type(principal_type), do: principal_type

  defp normalize_capability("sync_read"), do: :sync_read
  defp normalize_capability("sync_write"), do: :sync_write
  defp normalize_capability(capability), do: capability

  defp normalize_principal_type_value(:pubkey), do: {:ok, "pubkey"}
  defp normalize_principal_type_value("pubkey"), do: {:ok, "pubkey"}
  defp normalize_principal_type_value(_principal_type), do: {:error, :invalid_acl_principal_type}

  defp normalize_capability_value(:sync_read), do: {:ok, "sync_read"}
  defp normalize_capability_value(:sync_write), do: {:ok, "sync_write"}
  defp normalize_capability_value("sync_read"), do: {:ok, "sync_read"}
  defp normalize_capability_value("sync_write"), do: {:ok, "sync_write"}
  defp normalize_capability_value(_capability), do: {:error, :invalid_acl_capability}

  defp normalize_match_value(match) when is_map(match) do
    normalized_match =
      Enum.reduce(match, %{}, fn
        {key, values}, acc when is_binary(key) ->
          Map.put(acc, key, values)

        {key, values}, acc when is_atom(key) ->
          Map.put(acc, Atom.to_string(key), values)

        _entry, acc ->
          acc
      end)

    {:ok, normalize_match(normalized_match)}
  end

  defp normalize_match_value(_match), do: {:error, :invalid_acl_match}

  defp normalize_match(match) when is_map(match) do
    Enum.reduce(match, %{}, fn
      {key, values}, acc when is_binary(key) and is_list(values) ->
        Map.put(acc, key, Enum.uniq(values))

      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_match(_match), do: %{}

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp decode_hex_or_binary(value, expected_bytes, _reason)
       when is_binary(value) and byte_size(value) == expected_bytes,
       do: {:ok, value}

  defp decode_hex_or_binary(value, expected_bytes, reason) when is_binary(value) do
    if byte_size(value) == expected_bytes * 2 do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp decode_hex_or_binary(_value, _expected_bytes, reason), do: {:error, reason}
end
