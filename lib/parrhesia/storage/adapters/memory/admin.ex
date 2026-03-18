defmodule Parrhesia.Storage.Adapters.Memory.Admin do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.Admin`.
  """

  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.Admin
  @default_limit 100
  @max_limit 1_000
  @max_audit_logs 1_000

  @impl true
  def execute(_context, method, _params) do
    case method do
      method when method in [:ping, "ping"] -> {:ok, %{"status" => "ok"}}
      _other -> {:error, {:unsupported_method, normalize_method(method)}}
    end
  end

  @impl true
  def append_audit_log(_context, audit_entry) when is_map(audit_entry) do
    Store.update(fn state ->
      update_in(state.audit_logs, fn logs ->
        [audit_entry | logs] |> Enum.take(@max_audit_logs)
      end)
    end)

    :ok
  end

  def append_audit_log(_context, _audit_entry), do: {:error, :invalid_audit_entry}

  @impl true
  def list_audit_logs(_context, opts) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    method = normalize_method_filter(Keyword.get(opts, :method))
    actor_pubkey = Keyword.get(opts, :actor_pubkey)

    logs =
      Store.get(fn state ->
        state.audit_logs
        |> Enum.filter(&matches_filters?(&1, method, actor_pubkey))
        |> Enum.take(limit)
      end)

    {:ok, logs}
  end

  def list_audit_logs(_context, _opts), do: {:error, :invalid_opts}

  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method(method), do: inspect(method)

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp normalize_limit(_limit), do: @default_limit

  defp normalize_method_filter(nil), do: nil
  defp normalize_method_filter(method), do: normalize_method(method)

  defp matches_method?(_entry, nil), do: true

  defp matches_method?(entry, method) do
    normalize_method(Map.get(entry, :method) || Map.get(entry, "method")) == method
  end

  defp matches_actor_pubkey?(_entry, nil), do: true

  defp matches_actor_pubkey?(entry, actor_pubkey) do
    Map.get(entry, :actor_pubkey) == actor_pubkey or
      Map.get(entry, "actor_pubkey") == actor_pubkey
  end

  defp matches_filters?(entry, method, actor_pubkey) do
    matches_method?(entry, method) and matches_actor_pubkey?(entry, actor_pubkey)
  end
end
