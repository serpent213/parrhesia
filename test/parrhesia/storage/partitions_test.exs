defmodule Parrhesia.Storage.PartitionsTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Storage.Partitions

  test "list_partitions returns partition tables" do
    partitions = Partitions.list_partitions()
    assert is_list(partitions)
  end

  test "ensure_monthly_partitions creates aligned monthly partitions for events and event_tags" do
    assert :ok =
             Partitions.ensure_monthly_partitions(reference_date: ~D[2026-06-14], months_ahead: 1)

    monthly_partition_names =
      Partitions.list_monthly_partitions()
      |> Enum.map(& &1.name)

    assert "events_2026_06" in monthly_partition_names
    assert "events_2026_07" in monthly_partition_names

    assert table_exists?("event_tags_2026_06")
    assert table_exists?("event_tags_2026_07")
  end

  test "drop_partition returns an error for protected partitions" do
    assert {:error, :protected_partition} = Partitions.drop_partition("events_default")
    assert {:error, :protected_partition} = Partitions.drop_partition("events")
    assert {:error, :protected_partition} = Partitions.drop_partition("event_tags_default")
    assert {:error, :protected_partition} = Partitions.drop_partition("event_tags")
  end

  test "drop_partition removes aligned event_tags partition for monthly event partition" do
    assert :ok =
             Partitions.ensure_monthly_partitions(reference_date: ~D[2026-08-14], months_ahead: 0)

    assert table_exists?("events_2026_08")
    assert table_exists?("event_tags_2026_08")

    assert :ok = Partitions.drop_partition("events_2026_08")

    refute table_exists?("events_2026_08")
    refute table_exists?("event_tags_2026_08")
  end

  test "database_size_bytes returns the current database size" do
    assert {:ok, size} = Partitions.database_size_bytes()
    assert is_integer(size)
    assert size >= 0
  end

  defp table_exists?(table_name) when is_binary(table_name) do
    case Repo.query("SELECT to_regclass($1)", ["public." <> table_name]) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, %{rows: [[_relation_name]]}} -> true
      _other -> false
    end
  end
end
