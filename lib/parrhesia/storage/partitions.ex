defmodule Parrhesia.Storage.Partitions do
  @moduledoc """
  Partition lifecycle helpers for Postgres `events` and `event_tags` monthly partitions.
  """

  import Ecto.Query

  alias Parrhesia.PostgresRepos
  alias Parrhesia.Repo

  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @monthly_partition_pattern ~r/^events_(\d{4})_(\d{2})$/
  @events_partition_prefix "events"
  @event_tags_partition_prefix "event_tags"
  @default_months_ahead 2

  @type monthly_partition :: %{
          name: String.t(),
          year: pos_integer(),
          month: pos_integer(),
          month_start_unix: non_neg_integer(),
          month_end_unix: non_neg_integer()
        }

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

    read_repo()
    |> then(fn repo -> repo.all(query) end)
  end

  @doc """
  Lists monthly event partitions that match `events_YYYY_MM` naming.
  """
  @spec list_monthly_partitions() :: [monthly_partition()]
  def list_monthly_partitions do
    list_partitions()
    |> Enum.map(&parse_monthly_partition/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{&1.year, &1.month})
  end

  @doc """
  Ensures monthly partitions exist for the current month and `months_ahead` future months.
  """
  @spec ensure_monthly_partitions(keyword()) :: :ok | {:error, term()}
  def ensure_monthly_partitions(opts \\ []) when is_list(opts) do
    months_ahead =
      opts
      |> Keyword.get(:months_ahead, @default_months_ahead)
      |> normalize_non_negative_integer(@default_months_ahead)

    reference_date =
      opts
      |> Keyword.get(:reference_date, Date.utc_today())
      |> normalize_reference_date()

    reference_month = month_start(reference_date)

    offsets =
      if months_ahead == 0 do
        [0]
      else
        Enum.to_list(0..months_ahead)
      end

    Enum.reduce_while(offsets, :ok, fn offset, :ok ->
      target_month = shift_month(reference_month, offset)

      case create_monthly_partitions(target_month) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Returns the current database size in bytes.
  """
  @spec database_size_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def database_size_bytes do
    repo = read_repo()

    case repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[size]]}} when is_integer(size) and size >= 0 -> {:ok, size}
      {:ok, _result} -> {:error, :unexpected_result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Drops an event partition table by name.

  For monthly `events_YYYY_MM` partitions, the matching `event_tags_YYYY_MM`
  partition is dropped first to keep partition lifecycle aligned.
  """
  @spec drop_partition(String.t()) :: :ok | {:error, term()}
  def drop_partition(partition_name) when is_binary(partition_name) do
    if protected_partition?(partition_name) do
      {:error, :protected_partition}
    else
      drop_partition_tables(partition_name)
    end
  end

  @doc """
  Returns the monthly `events` partition name for a date.
  """
  @spec month_partition_name(Date.t()) :: String.t()
  def month_partition_name(%Date{} = date) do
    monthly_partition_name(@events_partition_prefix, date)
  end

  @doc """
  Returns the monthly `event_tags` partition name for a date.
  """
  @spec event_tags_month_partition_name(Date.t()) :: String.t()
  def event_tags_month_partition_name(%Date{} = date) do
    monthly_partition_name(@event_tags_partition_prefix, date)
  end

  defp monthly_partition_name(prefix, %Date{} = date) do
    month_suffix = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{prefix}_#{date.year}_#{month_suffix}"
  end

  defp create_monthly_partitions(%Date{} = month_date) do
    {start_unix, end_unix} = month_bounds_unix(month_date.year, month_date.month)

    case create_monthly_partition(
           month_partition_name(month_date),
           @events_partition_prefix,
           start_unix,
           end_unix
         ) do
      :ok ->
        create_monthly_partition(
          event_tags_month_partition_name(month_date),
          @event_tags_partition_prefix,
          start_unix,
          end_unix
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_monthly_partition(partition_name, parent_table_name, start_unix, end_unix) do
    quoted_partition_name = quote_identifier!(partition_name)
    quoted_parent_table_name = quote_identifier!(parent_table_name)

    sql =
      """
      CREATE TABLE IF NOT EXISTS #{quoted_partition_name}
      PARTITION OF #{quoted_parent_table_name}
      FOR VALUES FROM (#{start_unix}) TO (#{end_unix})
      """

    case Repo.query(sql) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_partition_tables(partition_name) do
    case parse_monthly_partition(partition_name) do
      nil -> drop_table(partition_name)
      monthly_partition -> drop_monthly_partition(partition_name, monthly_partition)
    end
  end

  defp drop_monthly_partition(partition_name, %{year: year, month: month}) do
    month_date = Date.new!(year, month, 1)
    tags_partition_name = monthly_partition_name(@event_tags_partition_prefix, month_date)

    with :ok <- maybe_detach_events_partition(partition_name),
         :ok <- drop_table(tags_partition_name) do
      drop_table(partition_name)
    end
  end

  defp maybe_detach_events_partition(partition_name) do
    if attached_partition?(partition_name, @events_partition_prefix) do
      quoted_parent_table_name = quote_identifier!(@events_partition_prefix)
      quoted_partition_name = quote_identifier!(partition_name)

      case Repo.query(
             "ALTER TABLE #{quoted_parent_table_name} DETACH PARTITION #{quoted_partition_name}"
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp attached_partition?(partition_name, parent_table_name) do
    query =
      """
      SELECT 1
      FROM pg_inherits AS inheritance
      JOIN pg_class AS child ON child.oid = inheritance.inhrelid
      JOIN pg_namespace AS child_ns ON child_ns.oid = child.relnamespace
      JOIN pg_class AS parent ON parent.oid = inheritance.inhparent
      JOIN pg_namespace AS parent_ns ON parent_ns.oid = parent.relnamespace
      WHERE child_ns.nspname = 'public'
        AND parent_ns.nspname = 'public'
        AND child.relname = $1
        AND parent.relname = $2
      LIMIT 1
      """

    repo = read_repo()

    case repo.query(query, [partition_name, parent_table_name]) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: []}} -> false
      {:ok, _result} -> false
      {:error, _reason} -> false
    end
  end

  defp drop_table(table_name) do
    quoted_table_name = quote_identifier!(table_name)

    case Repo.query("DROP TABLE IF EXISTS #{quoted_table_name}") do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp protected_partition?(partition_name) do
    partition_name in ["events", "events_default", "event_tags", "event_tags_default"]
  end

  defp parse_monthly_partition(partition_name) do
    case Regex.run(@monthly_partition_pattern, partition_name, capture: :all_but_first) do
      [year_text, month_text] ->
        {year, ""} = Integer.parse(year_text)
        {month, ""} = Integer.parse(month_text)

        if month in 1..12 do
          {month_start_unix, month_end_unix} = month_bounds_unix(year, month)

          %{
            name: partition_name,
            year: year,
            month: month,
            month_start_unix: month_start_unix,
            month_end_unix: month_end_unix
          }
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp month_bounds_unix(year, month) do
    month_date = Date.new!(year, month, 1)
    next_month_date = shift_month(month_date, 1)

    {date_to_unix(month_date), date_to_unix(next_month_date)}
  end

  defp date_to_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp read_repo, do: PostgresRepos.read()

  defp month_start(%Date{} = date), do: Date.new!(date.year, date.month, 1)

  defp shift_month(%Date{} = date, month_delta) when is_integer(month_delta) do
    month_index = date.year * 12 + date.month - 1 + month_delta
    shifted_year = div(month_index, 12)
    shifted_month = rem(month_index, 12) + 1

    Date.new!(shifted_year, shifted_month, 1)
  end

  defp normalize_reference_date(%Date{} = date), do: date
  defp normalize_reference_date(_other), do: Date.utc_today()

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(_value, default), do: default

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
