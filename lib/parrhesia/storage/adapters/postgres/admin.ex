defmodule Parrhesia.Storage.Adapters.Postgres.Admin do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Admin`.
  """

  import Ecto.Query

  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Admin

  @default_limit 100
  @max_limit 1_000

  @impl true
  def execute(_context, method, params) when is_map(params) do
    moderation = Parrhesia.Storage.moderation()
    method_name = normalize_method_name(method)

    case method_name do
      "ping" -> {:ok, %{"status" => "ok"}}
      "stats" -> {:ok, relay_stats()}
      "list_audit_logs" -> list_audit_logs(%{}, audit_list_opts(params))
      _other -> execute_moderation_method(moderation, method_name, params)
    end
  end

  def execute(_context, method, _params),
    do: {:error, {:unsupported_method, normalize_method_name(method)}}

  @impl true
  def append_audit_log(_context, audit_entry) when is_map(audit_entry) do
    with {:ok, method} <- fetch_required_method(audit_entry),
         {:ok, actor_pubkey} <- fetch_optional_pubkey(audit_entry),
         {:ok, params} <- fetch_optional_map(audit_entry, :params),
         {:ok, result} <- fetch_optional_map(audit_entry, :result, true) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {inserted, _result} =
        Repo.insert_all("management_audit_logs", [
          audit_log_row(method, actor_pubkey, params, result, now)
        ])

      if inserted == 1 do
        :ok
      else
        {:error, :audit_log_insert_failed}
      end
    end
  end

  def append_audit_log(_context, _audit_entry), do: {:error, :invalid_audit_entry}

  @impl true
  def list_audit_logs(_context, opts) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))

    query =
      from(log in "management_audit_logs",
        order_by: [desc: log.inserted_at, desc: log.id],
        limit: ^limit,
        select: %{
          id: log.id,
          actor_pubkey: log.actor_pubkey,
          method: log.method,
          params: log.params,
          result: log.result,
          inserted_at: log.inserted_at
        }
      )
      |> maybe_filter_method(Keyword.get(opts, :method))
      |> maybe_filter_actor_pubkey(Keyword.get(opts, :actor_pubkey))

    logs =
      query
      |> Repo.all()
      |> Enum.map(&to_audit_log_map/1)

    {:ok, logs}
  end

  def list_audit_logs(_context, _opts), do: {:error, :invalid_opts}

  defp relay_stats do
    events_count = Repo.aggregate("events", :count, :id)
    banned_pubkeys = Repo.aggregate("banned_pubkeys", :count, :pubkey)
    blocked_ips = Repo.aggregate("blocked_ips", :count, :ip)

    %{
      "events" => events_count,
      "banned_pubkeys" => banned_pubkeys,
      "blocked_ips" => blocked_ips
    }
  end

  defp execute_moderation_method(moderation, "ban_pubkey", params),
    do: execute_pubkey_method(fn ctx, value -> moderation.ban_pubkey(ctx, value) end, params)

  defp execute_moderation_method(moderation, "unban_pubkey", params),
    do: execute_pubkey_method(fn ctx, value -> moderation.unban_pubkey(ctx, value) end, params)

  defp execute_moderation_method(moderation, "allow_pubkey", params),
    do: execute_pubkey_method(fn ctx, value -> moderation.allow_pubkey(ctx, value) end, params)

  defp execute_moderation_method(moderation, "disallow_pubkey", params),
    do: execute_pubkey_method(fn ctx, value -> moderation.disallow_pubkey(ctx, value) end, params)

  defp execute_moderation_method(moderation, "ban_event", params),
    do: execute_event_method(fn ctx, value -> moderation.ban_event(ctx, value) end, params)

  defp execute_moderation_method(moderation, "unban_event", params),
    do: execute_event_method(fn ctx, value -> moderation.unban_event(ctx, value) end, params)

  defp execute_moderation_method(moderation, "block_ip", params),
    do: execute_ip_method(fn ctx, value -> moderation.block_ip(ctx, value) end, params)

  defp execute_moderation_method(moderation, "unblock_ip", params),
    do: execute_ip_method(fn ctx, value -> moderation.unblock_ip(ctx, value) end, params)

  defp execute_moderation_method(_moderation, method_name, _params),
    do: {:error, {:unsupported_method, method_name}}

  defp audit_list_opts(params) do
    []
    |> maybe_put_opt(:limit, Map.get(params, "limit"))
    |> maybe_put_opt(:method, Map.get(params, "method"))
    |> maybe_put_opt(:actor_pubkey, Map.get(params, "actor_pubkey"))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp execute_pubkey_method(fun, params) do
    case Map.get(params, "pubkey") do
      pubkey when is_binary(pubkey) ->
        with :ok <- fun.(%{}, pubkey) do
          {:ok, %{"ok" => true}}
        end

      _other ->
        {:error, :invalid_pubkey}
    end
  end

  defp execute_event_method(fun, params) do
    case Map.get(params, "event_id") do
      event_id when is_binary(event_id) ->
        with :ok <- fun.(%{}, event_id) do
          {:ok, %{"ok" => true}}
        end

      _other ->
        {:error, :invalid_event_id}
    end
  end

  defp execute_ip_method(fun, params) do
    case Map.get(params, "ip") do
      ip when is_binary(ip) ->
        with :ok <- fun.(%{}, ip) do
          {:ok, %{"ok" => true}}
        end

      _other ->
        {:error, :invalid_ip}
    end
  end

  defp fetch_required_method(audit_entry) do
    audit_entry
    |> fetch_value(:method)
    |> normalize_non_empty_string(:invalid_method)
  end

  defp fetch_optional_pubkey(audit_entry) do
    case fetch_value(audit_entry, :actor_pubkey) do
      nil -> {:ok, nil}
      value -> normalize_pubkey(value)
    end
  end

  defp fetch_optional_map(audit_entry, key, allow_nil \\ false) do
    case fetch_value(audit_entry, key) do
      nil when allow_nil -> {:ok, nil}
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _value -> {:error, invalid_key_reason(key)}
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_method_name(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method_name(method) when is_binary(method), do: method
  defp normalize_method_name(method), do: inspect(method)

  defp normalize_non_empty_string(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_non_empty_string(_value, reason), do: {:error, reason}

  defp normalize_pubkey(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}

  defp normalize_pubkey(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, pubkey} -> {:ok, pubkey}
      :error -> {:error, :invalid_actor_pubkey}
    end
  end

  defp normalize_pubkey(_value), do: {:error, :invalid_actor_pubkey}

  defp invalid_key_reason(:params), do: :invalid_params
  defp invalid_key_reason(:result), do: :invalid_result

  defp audit_log_row(method, actor_pubkey, params, result, inserted_at) do
    %{
      method: method,
      actor_pubkey: actor_pubkey,
      params: params,
      result: result,
      inserted_at: inserted_at
    }
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_limit)
  end

  defp normalize_limit(_limit), do: @default_limit

  defp maybe_filter_method(query, nil), do: query

  defp maybe_filter_method(query, method) when is_atom(method) do
    maybe_filter_method(query, Atom.to_string(method))
  end

  defp maybe_filter_method(query, method) when is_binary(method) and method != "" do
    where(query, [log], log.method == ^method)
  end

  defp maybe_filter_method(query, _method), do: query

  defp maybe_filter_actor_pubkey(query, nil), do: query

  defp maybe_filter_actor_pubkey(query, actor_pubkey) do
    case normalize_pubkey(actor_pubkey) do
      {:ok, normalized_actor_pubkey} ->
        where(query, [log], log.actor_pubkey == ^normalized_actor_pubkey)

      {:error, _reason} ->
        where(query, [log], false)
    end
  end

  defp to_audit_log_map(log) do
    %{
      id: log.id,
      actor_pubkey: encode_optional_hex(log.actor_pubkey),
      method: log.method,
      params: log.params,
      result: log.result,
      inserted_at: log.inserted_at
    }
  end

  defp encode_optional_hex(nil), do: nil
  defp encode_optional_hex(value), do: Base.encode16(value, case: :lower)
end
