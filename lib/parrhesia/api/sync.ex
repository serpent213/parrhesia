defmodule Parrhesia.API.Sync do
  @moduledoc """
  Sync server control-plane API.

  This module manages outbound relay sync definitions and exposes runtime status for each
  configured sync worker.

  The main entrypoint is `put_server/2`. Accepted server maps are normalized into a stable
  internal shape and persisted by the sync manager. The expected input shape is:

  ```elixir
  %{
    "id" => "tribes-primary",
    "url" => "wss://relay-a.example/relay",
    "enabled?" => true,
    "auth_pubkey" => "...64 hex chars...",
    "filters" => [%{"kinds" => [5000]}],
    "mode" => "req_stream",
    "overlap_window_seconds" => 300,
    "auth" => %{"type" => "nip42"},
    "tls" => %{
      "mode" => "required",
      "hostname" => "relay-a.example",
      "pins" => [%{"type" => "spki_sha256", "value" => "..."}]
    },
    "metadata" => %{}
  }
  ```

  Most functions accept `:manager` or `:name` in `opts` to target a non-default manager.
  """

  alias Parrhesia.API.Sync.Manager

  @typedoc """
  Normalized sync server configuration returned by the sync manager.
  """
  @type server :: map()

  @doc """
  Creates or replaces a sync server definition.
  """
  @spec put_server(map(), keyword()) :: {:ok, server()} | {:error, term()}
  def put_server(server, opts \\ [])

  def put_server(server, opts) when is_map(server) and is_list(opts) do
    Manager.put_server(manager_name(opts), server)
  end

  def put_server(_server, _opts), do: {:error, :invalid_server}

  @doc """
  Removes a stored sync server definition and stops its worker if it is running.
  """
  @spec remove_server(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_server(server_id, opts \\ [])

  def remove_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.remove_server(manager_name(opts), server_id)
  end

  def remove_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Fetches a single normalized sync server definition.

  Returns `:error` when the server id is unknown.
  """
  @spec get_server(String.t(), keyword()) :: {:ok, server()} | :error | {:error, term()}
  def get_server(server_id, opts \\ [])

  def get_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.get_server(manager_name(opts), server_id)
  end

  def get_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Lists all configured sync servers, including their runtime state.
  """
  @spec list_servers(keyword()) :: {:ok, [server()]} | {:error, term()}
  def list_servers(opts \\ []) when is_list(opts) do
    Manager.list_servers(manager_name(opts))
  end

  @doc """
  Marks a sync server as running and reconciles its worker state.
  """
  @spec start_server(String.t(), keyword()) :: :ok | {:error, term()}
  def start_server(server_id, opts \\ [])

  def start_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.start_server(manager_name(opts), server_id)
  end

  def start_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Stops a sync server and records a disconnect timestamp in runtime state.
  """
  @spec stop_server(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_server(server_id, opts \\ [])

  def stop_server(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.stop_server(manager_name(opts), server_id)
  end

  def stop_server(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Triggers an immediate sync run for a server.
  """
  @spec sync_now(String.t(), keyword()) :: :ok | {:error, term()}
  def sync_now(server_id, opts \\ [])

  def sync_now(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.sync_now(manager_name(opts), server_id)
  end

  def sync_now(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Returns runtime counters and timestamps for a single sync server.

  Returns `:error` when the server id is unknown.
  """
  @spec server_stats(String.t(), keyword()) :: {:ok, map()} | :error | {:error, term()}
  def server_stats(server_id, opts \\ [])

  def server_stats(server_id, opts) when is_binary(server_id) and is_list(opts) do
    Manager.server_stats(manager_name(opts), server_id)
  end

  def server_stats(_server_id, _opts), do: {:error, :invalid_server_id}

  @doc """
  Returns aggregate counters across all configured sync servers.
  """
  @spec sync_stats(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_stats(opts \\ []) when is_list(opts) do
    Manager.sync_stats(manager_name(opts))
  end

  @doc """
  Returns a health summary for the sync subsystem.
  """
  @spec sync_health(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_health(opts \\ []) when is_list(opts) do
    Manager.sync_health(manager_name(opts))
  end

  @doc """
  Returns the default filesystem path for persisted sync server state.
  """
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
