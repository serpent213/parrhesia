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

  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @doc """
  Generates an archive SQL statement for the given partition.
  """
  @spec archive_sql(String.t(), String.t()) :: String.t()
  def archive_sql(partition_name, archive_table_name) do
    quoted_archive_table_name = quote_identifier!(archive_table_name)
    quoted_partition_name = quote_identifier!(partition_name)

    "INSERT INTO #{quoted_archive_table_name} SELECT * FROM #{quoted_partition_name};"
  end

  defp quote_identifier!(identifier) when is_binary(identifier) do
    if Regex.match?(@identifier_pattern, identifier) do
      ~s("#{identifier}")
    else
      raise ArgumentError, "invalid SQL identifier: #{inspect(identifier)}"
    end
  end

  defp quote_identifier!(identifier) do
    raise ArgumentError, "invalid SQL identifier: #{inspect(identifier)}"
  end
end
