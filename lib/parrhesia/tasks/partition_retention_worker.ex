defmodule Parrhesia.Tasks.PartitionRetentionWorker do
  @moduledoc """
  Periodic worker that ensures monthly event partitions and applies retention pruning.
  """

  use GenServer

  alias Parrhesia.Storage.Partitions
  alias Parrhesia.Telemetry

  @default_check_interval_hours 24
  @default_months_ahead 2
  @default_max_partitions_to_drop_per_run 1
  @bytes_per_gib 1_073_741_824

  @type monthly_partition :: Partitions.monthly_partition()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    retention_config = Application.get_env(:parrhesia, :retention, [])

    state = %{
      partition_ops: Keyword.get(opts, :partition_ops, Partitions),
      interval_ms: interval_ms(opts, retention_config),
      months_ahead: months_ahead(opts, retention_config),
      max_db_gib: max_db_gib(opts, retention_config),
      max_months_to_keep: max_months_to_keep(opts, retention_config),
      max_partitions_to_drop_per_run: max_partitions_to_drop_per_run(opts, retention_config),
      today_fun: today_fun(opts)
    }

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    started_at = System.monotonic_time()

    {dropped_count, status} =
      case run_maintenance(state) do
        {:ok, count} -> {count, :ok}
        {:error, _reason} -> {0, :error}
      end

    Telemetry.emit(
      [:parrhesia, :maintenance, :partition_retention, :stop],
      %{
        duration: System.monotonic_time() - started_at,
        dropped_partitions: dropped_count
      },
      %{status: status}
    )

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_maintenance(state) do
    case state.partition_ops.ensure_monthly_partitions(months_ahead: state.months_ahead) do
      :ok -> maybe_drop_oldest_partitions(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_drop_oldest_partitions(%{max_partitions_to_drop_per_run: max_drops})
       when max_drops <= 0,
       do: {:ok, 0}

  defp maybe_drop_oldest_partitions(state) do
    1..state.max_partitions_to_drop_per_run
    |> Enum.reduce_while({:ok, 0}, fn _attempt, {:ok, dropped_count} ->
      drop_oldest_partition_once(state, dropped_count)
    end)
  end

  defp drop_oldest_partition_once(state, dropped_count) do
    case next_partition_to_drop(state) do
      {:ok, partition} -> apply_partition_drop(state, partition, dropped_count)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp apply_partition_drop(_state, nil, dropped_count), do: {:halt, {:ok, dropped_count}}

  defp apply_partition_drop(state, partition, dropped_count) do
    case state.partition_ops.drop_partition(partition.name) do
      :ok -> {:cont, {:ok, dropped_count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp next_partition_to_drop(state) do
    partitions = state.partition_ops.list_monthly_partitions()
    current_month_index = current_month_index(state.today_fun)

    month_limit_candidate =
      oldest_partition_exceeding_month_limit(
        partitions,
        state.max_months_to_keep,
        current_month_index
      )

    with {:ok, size_limit_candidate} <-
           oldest_partition_exceeding_size_limit(
             partitions,
             state.max_db_gib,
             current_month_index,
             state.partition_ops
           ) do
      {:ok, pick_oldest_partition(month_limit_candidate, size_limit_candidate)}
    end
  end

  defp oldest_partition_exceeding_month_limit(_partitions, :infinity, _current_month_index),
    do: nil

  defp oldest_partition_exceeding_month_limit(partitions, max_months_to_keep, current_month_index)
       when is_integer(max_months_to_keep) and max_months_to_keep > 0 do
    oldest_month_to_keep_index = current_month_index - (max_months_to_keep - 1)

    partitions
    |> Enum.filter(fn partition ->
      month_index(partition) < current_month_index and
        month_index(partition) < oldest_month_to_keep_index
    end)
    |> Enum.min_by(&month_index/1, fn -> nil end)
  end

  defp oldest_partition_exceeding_month_limit(
         _partitions,
         _max_months_to_keep,
         _current_month_index
       ),
       do: nil

  defp oldest_partition_exceeding_size_limit(
         _partitions,
         :infinity,
         _current_month_index,
         _archiver
       ),
       do: {:ok, nil}

  defp oldest_partition_exceeding_size_limit(
         partitions,
         max_db_gib,
         current_month_index,
         archiver
       )
       when is_integer(max_db_gib) and max_db_gib > 0 do
    with {:ok, current_size_bytes} <- archiver.database_size_bytes() do
      max_size_bytes = max_db_gib * @bytes_per_gib

      if current_size_bytes > max_size_bytes do
        {:ok, oldest_completed_partition(partitions, current_month_index)}
      else
        {:ok, nil}
      end
    end
  end

  defp oldest_partition_exceeding_size_limit(
         _partitions,
         _max_db_gib,
         _current_month_index,
         _archiver
       ),
       do: {:ok, nil}

  defp oldest_completed_partition(partitions, current_month_index) do
    partitions
    |> Enum.filter(&(month_index(&1) < current_month_index))
    |> Enum.min_by(&month_index/1, fn -> nil end)
  end

  defp pick_oldest_partition(nil, nil), do: nil
  defp pick_oldest_partition(partition, nil), do: partition
  defp pick_oldest_partition(nil, partition), do: partition

  defp pick_oldest_partition(left, right) do
    if month_index(left) <= month_index(right) do
      left
    else
      right
    end
  end

  defp month_index(%{year: year, month: month}) when is_integer(year) and is_integer(month) do
    year * 12 + month
  end

  defp current_month_index(today_fun) do
    today = today_fun.()
    today.year * 12 + today.month
  end

  defp interval_ms(opts, retention_config) do
    case Keyword.get(opts, :interval_ms) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        retention_config
        |> Keyword.get(:check_interval_hours, @default_check_interval_hours)
        |> normalize_positive_integer(@default_check_interval_hours)
        |> hours_to_ms()
    end
  end

  defp months_ahead(opts, retention_config) do
    opts
    |> Keyword.get(
      :months_ahead,
      Keyword.get(retention_config, :months_ahead, @default_months_ahead)
    )
    |> normalize_non_negative_integer(@default_months_ahead)
  end

  defp max_db_gib(opts, retention_config) do
    opts
    |> Keyword.get(:max_db_bytes, Keyword.get(retention_config, :max_db_bytes, :infinity))
    |> normalize_limit()
  end

  defp max_months_to_keep(opts, retention_config) do
    opts
    |> Keyword.get(
      :max_months_to_keep,
      Keyword.get(retention_config, :max_months_to_keep, :infinity)
    )
    |> normalize_limit()
  end

  defp max_partitions_to_drop_per_run(opts, retention_config) do
    opts
    |> Keyword.get(
      :max_partitions_to_drop_per_run,
      Keyword.get(
        retention_config,
        :max_partitions_to_drop_per_run,
        @default_max_partitions_to_drop_per_run
      )
    )
    |> normalize_non_negative_integer(@default_max_partitions_to_drop_per_run)
  end

  defp today_fun(opts) do
    case Keyword.get(opts, :today_fun, &Date.utc_today/0) do
      function when is_function(function, 0) -> function
      _other -> &Date.utc_today/0
    end
  end

  defp normalize_limit(:infinity), do: :infinity
  defp normalize_limit(value) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value), do: :infinity

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(_value, default), do: default

  defp hours_to_ms(hours), do: hours * 60 * 60 * 1000

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
