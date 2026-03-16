defmodule Parrhesia.API.Admin do
  @moduledoc """
  Public management API facade.
  """

  alias Parrhesia.API.ACL
  alias Parrhesia.API.Identity
  alias Parrhesia.Storage

  @supported_acl_methods ~w(acl_grant acl_revoke acl_list)
  @supported_identity_methods ~w(identity_ensure identity_get identity_import identity_rotate)

  @spec execute(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(method, params, opts \\ [])

  def execute(method, params, _opts) when is_map(params) do
    method_name = normalize_method_name(method)

    case execute_builtin(method_name, params) do
      {:continue, other_method} -> Storage.admin().execute(%{}, other_method, params)
      result -> result
    end
  end

  def execute(method, _params, _opts),
    do: {:error, {:unsupported_method, normalize_method_name(method)}}

  @spec stats(keyword()) :: {:ok, map()} | {:error, term()}
  def stats(_opts \\ []), do: Storage.admin().execute(%{}, :stats, %{})

  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(_opts \\ []), do: {:ok, %{"status" => "ok"}}

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

    (storage_supported ++ @supported_acl_methods ++ @supported_identity_methods)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp identity_get(_params), do: Identity.get()

  defp identity_ensure(_params), do: Identity.ensure()

  defp identity_rotate(_params), do: Identity.rotate()

  defp identity_import(params) do
    Identity.import(params)
  end

  defp execute_builtin("acl_grant", params), do: acl_grant(params)
  defp execute_builtin("acl_revoke", params), do: acl_revoke(params)
  defp execute_builtin("acl_list", params), do: acl_list(params)
  defp execute_builtin("identity_get", params), do: identity_get(params)
  defp execute_builtin("identity_ensure", params), do: identity_ensure(params)
  defp execute_builtin("identity_import", params), do: identity_import(params)
  defp execute_builtin("identity_rotate", params), do: identity_rotate(params)

  defp execute_builtin("supportedmethods", _params),
    do: {:ok, %{"methods" => supported_methods()}}

  defp execute_builtin(other_method, _params), do: {:continue, other_method}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_method_name(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method_name(method) when is_binary(method), do: method
  defp normalize_method_name(method), do: inspect(method)
end
