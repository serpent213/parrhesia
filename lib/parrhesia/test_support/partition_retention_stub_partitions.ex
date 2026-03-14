defmodule Parrhesia.TestSupport.PartitionRetentionStubPartitions do
  @moduledoc false

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    initial_state = %{
      partitions: Keyword.get(opts, :partitions, []),
      db_size_bytes: Keyword.get(opts, :db_size_bytes, 0),
      test_pid: Keyword.get(opts, :test_pid)
    }

    Agent.start_link(fn -> initial_state end, name: name)
  end

  @spec ensure_monthly_partitions(keyword()) :: :ok
  def ensure_monthly_partitions(opts \\ []) do
    notify({:ensure_monthly_partitions, opts})
    :ok
  end

  @spec list_monthly_partitions() :: [map()]
  def list_monthly_partitions do
    Agent.get(__MODULE__, & &1.partitions)
  end

  @spec database_size_bytes() :: {:ok, non_neg_integer()}
  def database_size_bytes do
    notify(:database_size_bytes)
    {:ok, Agent.get(__MODULE__, & &1.db_size_bytes)}
  end

  @spec drop_partition(String.t()) :: :ok
  def drop_partition(partition_name) when is_binary(partition_name) do
    Agent.update(__MODULE__, fn state ->
      %{state | partitions: Enum.reject(state.partitions, &(&1.name == partition_name))}
    end)

    notify({:drop_partition, partition_name})
    :ok
  end

  defp notify(message) do
    case Agent.get(__MODULE__, & &1.test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
