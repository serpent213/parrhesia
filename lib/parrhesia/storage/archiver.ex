defmodule Parrhesia.Storage.Archiver do
  @moduledoc """
  Partition-aware archival helpers for Postgres event partitions.
  """

  import Ecto.Query

  alias Parrhesia.Repo

  @doc """
  Lists all `events_*` partitions excluding the default partition.
  """
  @spec list_partitions() :: [String.t()]
  def list_partitions do
    query =
      from(table in "pg_tables",
        where: table.schemaname == "public",
        where: like(table.tablename, "events_%"),
        where: table.tablename != "events_default",
        select: table.tablename,
        order_by: [asc: table.tablename]
      )

    Repo.all(query)
  end

  @doc """
  Generates an archive SQL statement for the given partition.
  """
  @spec archive_sql(String.t(), String.t()) :: String.t()
  def archive_sql(partition_name, archive_table_name) do
    "INSERT INTO #{archive_table_name} SELECT * FROM #{partition_name};"
  end
end
