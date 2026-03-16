defmodule Parrhesia.API.Admin do
  @moduledoc """
  Public management API facade.
  """

  alias Parrhesia.API.ACL
  alias Parrhesia.API.Identity
  alias Parrhesia.API.Sync
  alias Parrhesia.Storage

  @supported_acl_methods ~w(acl_grant acl_revoke acl_list)
  @supported_identity_methods ~w(identity_ensure identity_get identity_import identity_rotate)
  @supported_sync_methods ~w(
    sync_get_server
    sync_health
    sync_list_servers
    sync_put_server
    sync_remove_server
    sync_server_stats
    sync_start_server
    sync_stats
    sync_stop_server
    sync_sync_now
  )

  @spec execute(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(method, params, opts \\ [])

  def execute(method, params, opts) when is_map(params) do
    method_name = normalize_method_name(method)

    case execute_builtin(method_name, params, opts) do
      {:continue, other_method} -> Storage.admin().execute(%{}, other_method, params)
      result -> result
    end
  end

  def execute(method, _params, _opts),
    do: {:error, {:unsupported_method, normalize_method_name(method)}}

  @spec stats(keyword()) :: {:ok, map()} | {:error, term()}
  def stats(opts \\ []) do
    with {:ok, relay_stats} <- relay_stats(),
         {:ok, sync_stats} <- Sync.sync_stats(opts) do
      {:ok, Map.put(relay_stats, "sync", sync_stats)}
    end
  end

  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(opts \\ []) do
    with {:ok, sync_health} <- Sync.sync_health(opts) do
      {:ok,
       %{
         "status" => overall_health_status(sync_health),
         "sync" => sync_health
       }}
    end
  end

  @spec list_audit_logs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_audit_logs(opts \\ []) do
    Storage.admin().list_audit_logs(%{}, opts)
  end

  defp acl_grant(params) do
    with :ok <- ACL.grant(params) do
      {:ok, %{"ok" => true}}
    end
  end

  defp acl_revoke(params) do
    with :ok <- ACL.revoke(params) do
      {:ok, %{"ok" => true}}
    end
  end

  defp acl_list(params) do
    with {:ok, rules} <- ACL.list(acl_list_opts(params)) do
      {:ok, %{"rules" => rules}}
    end
  end

  defp acl_list_opts(params) do
    []
    |> maybe_put_opt(:principal_type, fetch_value(params, :principal_type))
    |> maybe_put_opt(:principal, fetch_value(params, :principal))
    |> maybe_put_opt(:capability, fetch_value(params, :capability))
  end

  defp supported_methods do
    storage_supported =
      case Storage.admin().execute(%{}, :supportedmethods, %{}) do
        {:ok, methods} when is_list(methods) -> methods
        {:ok, %{"methods" => methods}} when is_list(methods) -> methods
        _other -> []
      end

    (storage_supported ++
       @supported_acl_methods ++ @supported_identity_methods ++ @supported_sync_methods)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp identity_get(_params), do: Identity.get()

  defp identity_ensure(_params), do: Identity.ensure()

  defp identity_rotate(_params), do: Identity.rotate()

  defp identity_import(params) do
    Identity.import(params)
  end

  defp sync_put_server(params, opts), do: Sync.put_server(params, opts)

  defp sync_remove_server(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         :ok <- Sync.remove_server(server_id, opts) do
      {:ok, %{"ok" => true}}
    end
  end

  defp sync_get_server(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         {:ok, server} <- Sync.get_server(server_id, opts) do
      {:ok, server}
    else
      :error -> {:error, :not_found}
      other -> other
    end
  end

  defp sync_list_servers(_params, opts), do: Sync.list_servers(opts)

  defp sync_start_server(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         :ok <- Sync.start_server(server_id, opts) do
      {:ok, %{"ok" => true}}
    end
  end

  defp sync_stop_server(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         :ok <- Sync.stop_server(server_id, opts) do
      {:ok, %{"ok" => true}}
    end
  end

  defp sync_sync_now(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         :ok <- Sync.sync_now(server_id, opts) do
      {:ok, %{"ok" => true}}
    end
  end

  defp sync_server_stats(params, opts) do
    with {:ok, server_id} <- fetch_required_string(params, :id),
         {:ok, stats} <- Sync.server_stats(server_id, opts) do
      {:ok, stats}
    else
      :error -> {:error, :not_found}
      other -> other
    end
  end

  defp sync_stats(_params, opts), do: Sync.sync_stats(opts)
  defp sync_health(_params, opts), do: Sync.sync_health(opts)

  defp execute_builtin("acl_grant", params, _opts), do: acl_grant(params)
  defp execute_builtin("acl_revoke", params, _opts), do: acl_revoke(params)
  defp execute_builtin("acl_list", params, _opts), do: acl_list(params)
  defp execute_builtin("identity_get", params, _opts), do: identity_get(params)
  defp execute_builtin("identity_ensure", params, _opts), do: identity_ensure(params)
  defp execute_builtin("identity_import", params, _opts), do: identity_import(params)
  defp execute_builtin("identity_rotate", params, _opts), do: identity_rotate(params)
  defp execute_builtin("sync_put_server", params, opts), do: sync_put_server(params, opts)
  defp execute_builtin("sync_remove_server", params, opts), do: sync_remove_server(params, opts)
  defp execute_builtin("sync_get_server", params, opts), do: sync_get_server(params, opts)
  defp execute_builtin("sync_list_servers", params, opts), do: sync_list_servers(params, opts)
  defp execute_builtin("sync_start_server", params, opts), do: sync_start_server(params, opts)
  defp execute_builtin("sync_stop_server", params, opts), do: sync_stop_server(params, opts)
  defp execute_builtin("sync_sync_now", params, opts), do: sync_sync_now(params, opts)
  defp execute_builtin("sync_server_stats", params, opts), do: sync_server_stats(params, opts)
  defp execute_builtin("sync_stats", params, opts), do: sync_stats(params, opts)
  defp execute_builtin("sync_health", params, opts), do: sync_health(params, opts)

  defp execute_builtin("supportedmethods", _params, _opts),
    do: {:ok, %{"methods" => supported_methods()}}

  defp execute_builtin(other_method, _params, _opts), do: {:continue, other_method}

  defp relay_stats do
    case Storage.admin().execute(%{}, :stats, %{}) do
      {:ok, stats} when is_map(stats) -> {:ok, stats}
      {:error, {:unsupported_method, _method}} -> {:ok, %{}}
      other -> other
    end
  end

  defp overall_health_status(%{"status" => "degraded"}), do: "degraded"
  defp overall_health_status(_sync_health), do: "ok"

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch_required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_param, Atom.to_string(key)}}
    end
  end

  defp fetch_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_method_name(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method_name(method) when is_binary(method), do: method
  defp normalize_method_name(method), do: inspect(method)
end
