defmodule Parrhesia.Storage.Adapters.Postgres.ModerationCache do
  @moduledoc """
  ETS owner process for moderation cache tables.
  """

  use GenServer

  @cache_table :parrhesia_moderation_cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    _table =
      :ets.new(@cache_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
