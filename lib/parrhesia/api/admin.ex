defmodule Parrhesia.API.Admin do
  @moduledoc """
  Public management API facade.
  """

  alias Parrhesia.API.ACL
  alias Parrhesia.Storage

  @supported_acl_methods ~w(acl_grant acl_revoke acl_list)

  @spec execute(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(method, params, opts \\ [])

  def execute(method, params, _opts) when is_map(params) do
    case normalize_method_name(method) do
      "acl_grant" -> acl_grant(params)
      "acl_revoke" -> acl_revoke(params)
      "acl_list" -> acl_list(params)
      "supportedmethods" -> {:ok, %{"methods" => supported_methods()}}
      other_method -> Storage.admin().execute(%{}, other_method, params)
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

    (storage_supported ++ @supported_acl_methods)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_method_name(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method_name(method) when is_binary(method), do: method
  defp normalize_method_name(method), do: inspect(method)
end
