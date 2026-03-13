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
  def execute(_context, method, _params) do
    {:error, {:unsupported_method, normalize_method_name(method)}}
  end

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
