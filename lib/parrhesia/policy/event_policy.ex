defmodule Parrhesia.Policy.EventPolicy do
  @moduledoc """
  Write/read policy checks for relay operations.
  """

  alias Parrhesia.Storage

  @type policy_error ::
          :auth_required
          | :restricted_giftwrap
          | :protected_event_requires_auth
          | :protected_event_pubkey_mismatch
          | :pow_below_minimum
          | :pubkey_banned
          | :event_banned
          | :mls_disabled

  @spec authorize_read([map()], MapSet.t(String.t())) :: :ok | {:error, policy_error()}
  def authorize_read(filters, authenticated_pubkeys) when is_list(filters) do
    auth_required? = config_bool([:policies, :auth_required_for_reads], false)

    cond do
      auth_required? and MapSet.size(authenticated_pubkeys) == 0 ->
        {:error, :auth_required}

      giftwrap_restricted?(filters, authenticated_pubkeys) ->
        {:error, :restricted_giftwrap}

      true ->
        :ok
    end
  end

  @spec authorize_write(map(), MapSet.t(String.t())) :: :ok | {:error, policy_error()}
  def authorize_write(event, authenticated_pubkeys) when is_map(event) do
    checks = [
      fn -> maybe_require_auth_for_write(authenticated_pubkeys) end,
      fn -> reject_if_pubkey_banned(event) end,
      fn -> reject_if_event_banned(event) end,
      fn -> enforce_pow(event) end,
      fn -> enforce_protected_event(event, authenticated_pubkeys) end,
      fn -> enforce_mls_feature_flag(event) end
    ]

    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.() do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec error_message(policy_error()) :: String.t()
  def error_message(:auth_required), do: "auth-required: authentication required"

  def error_message(:restricted_giftwrap),
    do: "restricted: giftwrap access requires recipient authentication"

  def error_message(:protected_event_requires_auth),
    do: "auth-required: protected events require authenticated pubkey"

  def error_message(:protected_event_pubkey_mismatch),
    do: "restricted: protected event pubkey does not match authenticated pubkey"

  def error_message(:pow_below_minimum), do: "pow: minimum proof-of-work difficulty not met"
  def error_message(:pubkey_banned), do: "blocked: pubkey is banned"
  def error_message(:event_banned), do: "blocked: event is banned"
  def error_message(:mls_disabled), do: "blocked: mls feature flag is disabled"

  defp maybe_require_auth_for_write(authenticated_pubkeys) do
    if config_bool([:policies, :auth_required_for_writes], false) and
         MapSet.size(authenticated_pubkeys) == 0 do
      {:error, :auth_required}
    else
      :ok
    end
  end

  defp giftwrap_restricted?(filters, authenticated_pubkeys) do
    if MapSet.size(authenticated_pubkeys) == 0 do
      any_filter_targets_giftwrap?(filters)
    else
      not giftwrap_filters_include_authenticated_recipient?(filters, authenticated_pubkeys)
    end
  end

  defp any_filter_targets_giftwrap?(filters) do
    Enum.any?(filters, fn filter ->
      case Map.get(filter, "kinds") do
        kinds when is_list(kinds) -> 1059 in kinds
        _other -> false
      end
    end)
  end

  defp giftwrap_filters_include_authenticated_recipient?(filters, authenticated_pubkeys) do
    Enum.all?(filters, fn filter ->
      if targets_giftwrap?(filter) do
        recipients = Map.get(filter, "#p") || []
        recipients != [] and Enum.any?(recipients, &MapSet.member?(authenticated_pubkeys, &1))
      else
        true
      end
    end)
  end

  defp targets_giftwrap?(filter) do
    case Map.get(filter, "kinds") do
      kinds when is_list(kinds) -> 1059 in kinds
      _other -> false
    end
  end

  defp reject_if_pubkey_banned(event) do
    with pubkey when is_binary(pubkey) <- Map.get(event, "pubkey"),
         {:ok, true} <- Storage.moderation().pubkey_banned?(%{}, pubkey) do
      {:error, :pubkey_banned}
    else
      {:ok, false} -> :ok
      _other -> :ok
    end
  end

  defp reject_if_event_banned(event) do
    with event_id when is_binary(event_id) <- Map.get(event, "id"),
         {:ok, true} <- Storage.moderation().event_banned?(%{}, event_id) do
      {:error, :event_banned}
    else
      {:ok, false} -> :ok
      _other -> :ok
    end
  end

  defp enforce_pow(event) do
    min_difficulty = config_int([:policies, :min_pow_difficulty], 0)

    if min_difficulty <= 0 do
      :ok
    else
      difficulty = event_pow_difficulty(event)

      if difficulty >= min_difficulty do
        :ok
      else
        {:error, :pow_below_minimum}
      end
    end
  end

  defp event_pow_difficulty(event) do
    event
    |> Map.get("id", "")
    |> String.downcase()
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "0", acc -> {:cont, acc + 4}
      hex, acc -> {:halt, acc + leading_zero_bits(hex)}
    end)
  end

  defp leading_zero_bits("1"), do: 3
  defp leading_zero_bits("2"), do: 2
  defp leading_zero_bits("3"), do: 2
  defp leading_zero_bits("4"), do: 1
  defp leading_zero_bits("5"), do: 1
  defp leading_zero_bits("6"), do: 1
  defp leading_zero_bits("7"), do: 1
  defp leading_zero_bits("8"), do: 0
  defp leading_zero_bits("9"), do: 0
  defp leading_zero_bits("a"), do: 0
  defp leading_zero_bits("b"), do: 0
  defp leading_zero_bits("c"), do: 0
  defp leading_zero_bits("d"), do: 0
  defp leading_zero_bits("e"), do: 0
  defp leading_zero_bits("f"), do: 0
  defp leading_zero_bits(_other), do: 0

  defp enforce_protected_event(event, authenticated_pubkeys) do
    protected? =
      event
      |> Map.get("tags", [])
      |> Enum.any?(fn
        ["-" | _rest] -> true
        _tag -> false
      end)

    if protected? do
      pubkey = Map.get(event, "pubkey")

      cond do
        MapSet.size(authenticated_pubkeys) == 0 -> {:error, :protected_event_requires_auth}
        MapSet.member?(authenticated_pubkeys, pubkey) -> :ok
        true -> {:error, :protected_event_pubkey_mismatch}
      end
    else
      :ok
    end
  end

  defp enforce_mls_feature_flag(event) do
    if event["kind"] in [443, 445, 10_051] and not config_bool([:features, :nip_ee_mls], false) do
      {:error, :mls_disabled}
    else
      :ok
    end
  end

  defp config_bool([scope, key], default) do
    case Application.get_env(:parrhesia, scope, []) |> Keyword.get(key, default) do
      true -> true
      false -> false
      _other -> default
    end
  end

  defp config_int([scope, key], default) do
    case Application.get_env(:parrhesia, scope, []) |> Keyword.get(key, default) do
      value when is_integer(value) -> value
      _other -> default
    end
  end
end
