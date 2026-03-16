defmodule Parrhesia.API.ACL do
  @moduledoc """
  Public ACL API and rule matching for protected sync traffic.
  """

  alias Parrhesia.API.RequestContext
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Storage

  @spec grant(map(), keyword()) :: :ok | {:error, term()}
  def grant(rule, _opts \\ []) do
    with {:ok, _stored_rule} <- Storage.acl().put_rule(%{}, normalize_rule(rule)) do
      :ok
    end
  end

  @spec revoke(map(), keyword()) :: :ok | {:error, term()}
  def revoke(rule, _opts \\ []) do
    Storage.acl().delete_rule(%{}, normalize_delete_selector(rule))
  end

  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    Storage.acl().list_rules(%{}, normalize_list_opts(opts))
  end

  @spec check(atom(), map(), keyword()) :: :ok | {:error, term()}
  def check(capability, subject, opts \\ [])

  def check(capability, subject, opts)
      when capability in [:sync_read, :sync_write] and is_map(subject) do
    context = Keyword.get(opts, :context, %RequestContext{})

    with {:ok, normalized_capability} <- normalize_capability(capability),
         {:ok, normalized_context} <- normalize_context(context),
         {:ok, protected_filters} <- protected_filters() do
      if protected_subject?(normalized_capability, subject, protected_filters) do
        authorize_subject(normalized_capability, subject, normalized_context)
      else
        :ok
      end
    end
  end

  def check(_capability, _subject, _opts), do: {:error, :invalid_acl_capability}

  @spec protected_read?(map()) :: boolean()
  def protected_read?(filter) when is_map(filter) do
    case protected_filters() do
      {:ok, protected_filters} ->
        protected_subject?(:sync_read, filter, protected_filters)

      {:error, _reason} ->
        false
    end
  end

  def protected_read?(_filter), do: false

  @spec protected_write?(map()) :: boolean()
  def protected_write?(event) when is_map(event) do
    case protected_filters() do
      {:ok, protected_filters} ->
        protected_subject?(:sync_write, event, protected_filters)

      {:error, _reason} ->
        false
    end
  end

  def protected_write?(_event), do: false

  defp authorize_subject(capability, subject, %RequestContext{} = context) do
    if MapSet.size(context.authenticated_pubkeys) == 0 do
      {:error, :auth_required}
    else
      capability
      |> list_rules_for_capability()
      |> authorize_against_rules(capability, context.authenticated_pubkeys, subject)
    end
  end

  defp list_rules_for_capability(capability) do
    Storage.acl().list_rules(%{}, principal_type: :pubkey, capability: capability)
  end

  defp authorize_against_rules({:ok, rules}, capability, authenticated_pubkeys, subject) do
    if Enum.any?(authenticated_pubkeys, &principal_authorized?(&1, subject, rules)) do
      :ok
    else
      {:error, denial_reason(capability)}
    end
  end

  defp authorize_against_rules({:error, reason}, _capability, _authenticated_pubkeys, _subject),
    do: {:error, reason}

  defp principal_authorized?(authenticated_pubkey, subject, rules) do
    Enum.any?(rules, fn rule ->
      rule.principal == authenticated_pubkey and
        rule_covers_subject?(rule.capability, rule.match, subject)
    end)
  end

  defp rule_covers_subject?(:sync_read, rule_match, filter),
    do: filter_within_rule?(filter, rule_match)

  defp rule_covers_subject?(:sync_write, rule_match, event),
    do: Filter.matches_filter?(event, rule_match)

  defp protected_subject?(:sync_read, filter, protected_filters) do
    Enum.any?(protected_filters, &filters_overlap?(filter, &1))
  end

  defp protected_subject?(:sync_write, event, protected_filters) do
    Enum.any?(protected_filters, &Filter.matches_filter?(event, &1))
  end

  defp filters_overlap?(left, right) when is_map(left) and is_map(right) do
    comparable_keys =
      left
      |> comparable_filter_keys(right)
      |> Enum.reject(&(&1 in ["limit", "search", "since", "until"]))

    Enum.all?(
      comparable_keys,
      &filter_constraint_compatible?(Map.get(left, &1), Map.get(right, &1), &1)
    ) and
      filter_ranges_overlap?(left, right)
  end

  defp filter_constraint_compatible?(nil, _right, _key), do: true
  defp filter_constraint_compatible?(_left, nil, _key), do: true

  defp filter_constraint_compatible?(left, right, _key) when is_list(left) and is_list(right) do
    MapSet.disjoint?(MapSet.new(left), MapSet.new(right)) == false
  end

  defp filter_constraint_compatible?(left, right, _key), do: left == right

  defp filter_within_rule?(filter, rule_match) when is_map(filter) and is_map(rule_match) do
    Enum.reject(rule_match, fn {key, _value} -> key in ["since", "until", "limit", "search"] end)
    |> Enum.all?(fn {key, rule_value} ->
      requested_value = Map.get(filter, key)
      requested_constraint_within_rule?(requested_value, rule_value, key)
    end) and filter_range_within_rule?(filter, rule_match)
  end

  defp requested_constraint_within_rule?(nil, _rule_value, _key), do: false

  defp requested_constraint_within_rule?(requested_values, rule_values, _key)
       when is_list(requested_values) and is_list(rule_values) do
    requested_values
    |> MapSet.new()
    |> MapSet.subset?(MapSet.new(rule_values))
  end

  defp requested_constraint_within_rule?(requested_value, rule_value, _key),
    do: requested_value == rule_value

  defp denial_reason(:sync_read), do: :sync_read_not_allowed
  defp denial_reason(:sync_write), do: :sync_write_not_allowed

  defp normalize_context(%RequestContext{} = context), do: {:ok, normalize_pubkeys(context)}
  defp normalize_context(_context), do: {:error, :invalid_context}

  defp normalize_pubkeys(%RequestContext{} = context) do
    normalized_pubkeys =
      context.authenticated_pubkeys
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    %RequestContext{context | authenticated_pubkeys: normalized_pubkeys}
  end

  defp normalize_rule(rule) when is_map(rule), do: rule
  defp normalize_rule(_rule), do: %{}

  defp normalize_delete_selector(selector) when is_map(selector), do: selector
  defp normalize_delete_selector(_selector), do: %{}

  defp normalize_list_opts(opts) do
    []
    |> maybe_put_opt(:principal_type, Keyword.get(opts, :principal_type))
    |> maybe_put_opt(:principal, normalize_list_principal(Keyword.get(opts, :principal)))
    |> maybe_put_opt(:capability, Keyword.get(opts, :capability))
  end

  defp normalize_list_principal(nil), do: nil

  defp normalize_list_principal(principal) when is_binary(principal),
    do: String.downcase(principal)

  defp normalize_list_principal(principal), do: principal

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_capability(capability) do
    case capability do
      :sync_read -> {:ok, :sync_read}
      :sync_write -> {:ok, :sync_write}
      _other -> {:error, :invalid_acl_capability}
    end
  end

  defp protected_filters do
    filters =
      :parrhesia
      |> Application.get_env(:acl, [])
      |> Keyword.get(:protected_filters, [])

    if is_list(filters) and
         Enum.all?(filters, &(match?(%{}, &1) and Filter.validate_filter(&1) == :ok)) do
      {:ok, filters}
    else
      {:error, :invalid_protected_filters}
    end
  end

  defp comparable_filter_keys(left, right) do
    Map.keys(left)
    |> Kernel.++(Map.keys(right))
    |> Enum.uniq()
  end

  defp filter_ranges_overlap?(left, right) do
    since = max(boundary_value(left, "since", :lower), boundary_value(right, "since", :lower))
    until = min(boundary_value(left, "until", :upper), boundary_value(right, "until", :upper))
    since <= until
  end

  defp filter_range_within_rule?(filter, rule_match) do
    requested_since = Map.get(filter, "since")
    requested_until = Map.get(filter, "until")
    rule_since = Map.get(rule_match, "since")
    rule_until = Map.get(rule_match, "until")

    lower_ok? =
      is_nil(rule_since) or (is_integer(requested_since) and requested_since >= rule_since)

    upper_ok? =
      is_nil(rule_until) or (is_integer(requested_until) and requested_until <= rule_until)

    lower_ok? and upper_ok?
  end

  defp boundary_value(filter, key, :lower), do: Map.get(filter, key, 0)
  defp boundary_value(filter, key, :upper), do: Map.get(filter, key, 9_223_372_036_854_775_807)
end
