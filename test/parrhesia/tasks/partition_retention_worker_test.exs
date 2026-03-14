defmodule Parrhesia.Tasks.PartitionRetentionWorkerTest do
  use ExUnit.Case, async: false

  alias Parrhesia.Tasks.PartitionRetentionWorker
  alias Parrhesia.TestSupport.PartitionRetentionStubArchiver

  @bytes_per_gib 1_073_741_824

  test "drops oldest partition when max_months_to_keep is exceeded" do
    start_supervised!(
      {PartitionRetentionStubArchiver,
       partitions: [
         partition(2026, 1),
         partition(2026, 2),
         partition(2026, 3),
         partition(2026, 4),
         partition(2026, 5)
       ],
       db_size_bytes: 2 * @bytes_per_gib,
       test_pid: self()}
    )

    worker =
      start_supervised!(
        {PartitionRetentionWorker,
         name: nil,
         archiver: PartitionRetentionStubArchiver,
         interval_ms: :timer.hours(24),
         months_ahead: 0,
         max_db_bytes: :infinity,
         max_months_to_keep: 3,
         max_partitions_to_drop_per_run: 1,
         today_fun: fn -> ~D[2026-06-15] end}
      )

    assert is_pid(worker)
    assert_receive {:ensure_monthly_partitions, [months_ahead: 0]}
    assert_receive {:drop_partition, "events_2026_01"}
    refute_receive {:drop_partition, _partition_name}, 20
    refute_receive :database_size_bytes, 20
  end

  test "drops oldest completed partition when size exceeds max_db_bytes" do
    start_supervised!(
      {PartitionRetentionStubArchiver,
       partitions: [partition(2026, 3), partition(2026, 4), partition(2026, 5)],
       db_size_bytes: 12 * @bytes_per_gib,
       test_pid: self()}
    )

    worker =
      start_supervised!(
        {PartitionRetentionWorker,
         name: nil,
         archiver: PartitionRetentionStubArchiver,
         interval_ms: :timer.hours(24),
         months_ahead: 0,
         max_db_bytes: 10,
         max_months_to_keep: :infinity,
         max_partitions_to_drop_per_run: 1,
         today_fun: fn -> ~D[2026-06-15] end}
      )

    assert is_pid(worker)
    assert_receive {:ensure_monthly_partitions, [months_ahead: 0]}
    assert_receive :database_size_bytes
    assert_receive {:drop_partition, "events_2026_03"}
  end

  test "does not drop partitions when both limits are infinity" do
    start_supervised!(
      {PartitionRetentionStubArchiver,
       partitions: [partition(2026, 1), partition(2026, 2), partition(2026, 3)],
       db_size_bytes: 50 * @bytes_per_gib,
       test_pid: self()}
    )

    worker =
      start_supervised!(
        {PartitionRetentionWorker,
         name: nil,
         archiver: PartitionRetentionStubArchiver,
         interval_ms: :timer.hours(24),
         months_ahead: 0,
         max_db_bytes: :infinity,
         max_months_to_keep: :infinity,
         max_partitions_to_drop_per_run: 1,
         today_fun: fn -> ~D[2026-06-15] end}
      )

    assert is_pid(worker)
    assert_receive {:ensure_monthly_partitions, [months_ahead: 0]}
    refute_receive :database_size_bytes, 20
    refute_receive {:drop_partition, _partition_name}, 20
  end

  defp partition(year, month) when is_integer(year) and is_integer(month) do
    month_name = month |> Integer.to_string() |> String.pad_leading(2, "0")
    month_start = Date.new!(year, month, 1)
    next_month_start = shift_month(month_start, 1)

    %{
      name: "events_#{year}_#{month_name}",
      year: year,
      month: month,
      month_start_unix: date_to_unix(month_start),
      month_end_unix: date_to_unix(next_month_start)
    }
  end

  defp shift_month(%Date{} = date, month_delta) when is_integer(month_delta) do
    month_index = date.year * 12 + date.month - 1 + month_delta
    shifted_year = div(month_index, 12)
    shifted_month = rem(month_index, 12) + 1

    Date.new!(shifted_year, shifted_month, 1)
  end

  defp date_to_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end
end
