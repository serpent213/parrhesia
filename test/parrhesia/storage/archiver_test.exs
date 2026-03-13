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

  test "archive_sql builds insert-select statement" do
    assert Archiver.archive_sql("events_2026_03", "events_archive") ==
             "INSERT INTO events_archive SELECT * FROM events_2026_03;"
  end
end
