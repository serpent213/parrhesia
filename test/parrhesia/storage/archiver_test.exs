defmodule Parrhesia.Storage.ArchiverTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Archiver

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "list_partitions returns partition tables" do
    partitions = Archiver.list_partitions()
    assert is_list(partitions)
  end

  test "ensure_monthly_partitions creates named monthly partitions" do
    assert :ok =
             Archiver.ensure_monthly_partitions(reference_date: ~D[2026-06-14], months_ahead: 1)

    monthly_partition_names =
      Archiver.list_monthly_partitions()
      |> Enum.map(& &1.name)

    assert "events_2026_06" in monthly_partition_names
    assert "events_2026_07" in monthly_partition_names
  end

  test "archive_sql builds insert-select statement" do
    assert Archiver.archive_sql("events_2026_03", "events_archive") ==
             ~s(INSERT INTO "events_archive" SELECT * FROM "events_2026_03";)
  end

  test "drop_partition returns an error for protected partitions" do
    assert {:error, :protected_partition} = Archiver.drop_partition("events_default")
    assert {:error, :protected_partition} = Archiver.drop_partition("events")
  end

  test "database_size_bytes returns the current database size" do
    assert {:ok, size} = Archiver.database_size_bytes()
    assert is_integer(size)
    assert size >= 0
  end

  test "archive_sql rejects invalid SQL identifiers" do
    assert_raise ArgumentError, fn ->
      Archiver.archive_sql("events_default; DROP TABLE events", "events_archive")
    end
  end
end
