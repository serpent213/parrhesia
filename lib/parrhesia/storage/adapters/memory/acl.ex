defmodule Parrhesia.Storage.Adapters.Memory.ACL do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.ACL`.
  """

  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.ACL

  @impl true
  def put_rule(_context, rule) when is_map(rule) do
    with {:ok, normalized_rule} <- normalize_rule(rule) do
      Store.get_and_update(fn state -> put_rule_in_state(state, normalized_rule) end)
    end
  end

  def put_rule(_context, _rule), do: {:error, :invalid_acl_rule}

  @impl true
  def delete_rule(_context, selector) when is_map(selector) do
    case normalize_delete_selector(selector) do
      {:ok, {:id, id}} ->
        Store.update(fn state ->
          %{state | acl_rules: Enum.reject(state.acl_rules, &(&1.id == id))}
        end)

        :ok

      {:ok, {:exact, rule}} ->
        Store.update(fn state ->
          %{state | acl_rules: Enum.reject(state.acl_rules, &same_rule?(&1, rule))}
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_rule(_context, _selector), do: {:error, :invalid_acl_rule}

  @impl true
  def list_rules(_context, opts) when is_list(opts) do
    rules =
      Store.get(fn state -> Enum.reverse(state.acl_rules) end)
      |> Enum.filter(fn rule ->
        matches_principal_type?(rule, Keyword.get(opts, :principal_type)) and
          matches_principal?(rule, Keyword.get(opts, :principal)) and
          matches_capability?(rule, Keyword.get(opts, :capability))
      end)

    {:ok, rules}
  end

  def list_rules(_context, _opts), do: {:error, :invalid_opts}

  defp put_rule_in_state(state, normalized_rule) do
    case Enum.find(state.acl_rules, &same_rule?(&1, normalized_rule)) do
      nil ->
        next_id = state.next_acl_rule_id
        persisted_rule = Map.put(normalized_rule, :id, next_id)

        {{:ok, persisted_rule},
         %{
           state
           | acl_rules: [persisted_rule | state.acl_rules],
             next_acl_rule_id: next_id + 1
         }}

      existing_rule ->
        {{:ok, existing_rule}, state}
    end
  end

  defp matches_principal_type?(_rule, nil), do: true
  defp matches_principal_type?(rule, principal_type), do: rule.principal_type == principal_type

  defp matches_principal?(_rule, nil), do: true
  defp matches_principal?(rule, principal), do: rule.principal == principal

  defp matches_capability?(_rule, nil), do: true
  defp matches_capability?(rule, capability), do: rule.capability == capability

  defp same_rule?(left, right) do
    left.principal_type == right.principal_type and
      left.principal == right.principal and
      left.capability == right.capability and
      left.match == right.match
  end

  defp normalize_delete_selector(%{"id" => id}), do: normalize_delete_selector(%{id: id})

  defp normalize_delete_selector(%{id: id}) when is_integer(id) and id > 0,
    do: {:ok, {:id, id}}

  defp normalize_delete_selector(selector) do
    case normalize_rule(selector) do
      {:ok, rule} -> {:ok, {:exact, rule}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_rule(rule) when is_map(rule) do
    with {:ok, principal_type} <- normalize_principal_type(fetch(rule, :principal_type)),
         {:ok, principal} <- normalize_principal(fetch(rule, :principal)),
         {:ok, capability} <- normalize_capability(fetch(rule, :capability)),
         {:ok, match} <- normalize_match(fetch(rule, :match)) do
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

  defp normalize_principal_type(:pubkey), do: {:ok, :pubkey}
  defp normalize_principal_type("pubkey"), do: {:ok, :pubkey}
  defp normalize_principal_type(_value), do: {:error, :invalid_acl_principal_type}

  defp normalize_principal(value) when is_binary(value) and byte_size(value) == 64,
    do: {:ok, String.downcase(value)}

  defp normalize_principal(_value), do: {:error, :invalid_acl_principal}

  defp normalize_capability(:sync_read), do: {:ok, :sync_read}
  defp normalize_capability(:sync_write), do: {:ok, :sync_write}
  defp normalize_capability("sync_read"), do: {:ok, :sync_read}
  defp normalize_capability("sync_write"), do: {:ok, :sync_write}
  defp normalize_capability(_value), do: {:error, :invalid_acl_capability}

  defp normalize_match(match) when is_map(match) do
    normalized_match =
      Enum.reduce(match, %{}, fn
        {key, values}, acc when is_binary(key) ->
          Map.put(acc, key, values)

        {key, values}, acc when is_atom(key) ->
          Map.put(acc, Atom.to_string(key), values)

        _entry, acc ->
          acc
      end)

    {:ok, normalized_match}
  end

  defp normalize_match(_match), do: {:error, :invalid_acl_match}

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
