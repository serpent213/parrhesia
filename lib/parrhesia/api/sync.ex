defmodule Parrhesia.API.Sync do
  @moduledoc """
  Sync server control-plane API.
  """

  alias Parrhesia.API.Sync.Manager

  @type server :: map()

  @spec put_server(map(), keyword()) :: {:ok, server()} | {:error, term()}
  def put_server(server, opts \\ [])

  def put_server(server, opts) when is_map(server) and is_list(opts) do
    Manager.put_server(manager_name(opts), server)
  end

  def put_server(_server, _opts), do: {:error, :invalid_server}

  @spec remove_server(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_server(server_id, opts \\ [])

  def remove_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.remove_server(manager_name(opts), server_id)
  end

  def remove_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec get_server(String.t(), keyword()) :: {:ok, server()} | :error | {:error, term()}
  def get_server(server_id, opts \\ [])

  def get_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.get_server(manager_name(opts), server_id)
  end

  def get_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec list_servers(keyword()) :: {:ok, [server()]} | {:error, term()}
  def list_servers(opts \\ []) when is_list(opts) do
    Manager.list_servers(manager_name(opts))
  end

  @spec start_server(String.t(), keyword()) :: :ok | {:error, term()}
  def start_server(server_id, opts \\ [])

  def start_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.start_server(manager_name(opts), server_id)
  end

  def start_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec stop_server(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_server(server_id, opts \\ [])

  def stop_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.stop_server(manager_name(opts), server_id)
  end

  def stop_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec sync_now(String.t(), keyword()) :: :ok | {:error, term()}
  def sync_now(server_id, opts \\ [])

  def sync_now(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.sync_now(manager_name(opts), server_id)
  end

  def sync_now(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec server_stats(String.t(), keyword()) :: {:ok, map()} | :error | {:error, term()}
  def server_stats(server_id, opts \\ [])

  def server_stats(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.server_stats(manager_name(opts), server_id)
  end

  def server_stats(_server_id, _opts), do: {:error, :invalid_server_id}

  @spec sync_stats(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_stats(opts \\ []) when is_list(opts) do
    Manager.sync_stats(manager_name(opts))
  end

  @spec sync_health(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_health(opts \\ []) when is_list(opts) do
    Manager.sync_health(manager_name(opts))
  end

  def default_path do
    Path.join([default_data_dir(), "sync_servers.json"])
  end

  defp manager_name(opts) do
    opts[:manager] || opts[:name] || Manager
  end

  defp default_data_dir do
    base_dir =
      System.get_env("XDG_DATA_HOME") ||
        Path.join(System.user_home!(), ".local/share")

    Path.join(base_dir, "parrhesia")
  end
end
