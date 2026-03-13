defmodule Parrhesia.Config do
  @moduledoc """
  Runtime configuration cache backed by ETS.
  """

  use GenServer

  @table __MODULE__
  @root_key :config

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    _table = :ets.new(@table, [:named_table, :public, read_concurrency: true])

    config =
      :parrhesia
      |> Application.get_all_env()
      |> Enum.into(%{})

    :ets.insert(@table, {@root_key, config})

    {:ok, %{}}
  end

  @spec all() :: map() | keyword()
  def all do
    case :ets.lookup(@table, @root_key) do
      [{@root_key, config}] -> config
      [] -> %{}
    end
  end

  @spec get([atom()], term()) :: term()
  def get(path, default \\ nil) when is_list(path) do
    case fetch(path) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch(path) do
    Enum.reduce_while(path, {:ok, all()}, fn key, {:ok, current} ->
      case fetch_key(current, key) do
        {:ok, value} -> {:cont, {:ok, value}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp fetch_key(current, key) when is_map(current), do: Map.fetch(current, key)

  defp fetch_key(current, key) when is_list(current) do
    if Keyword.keyword?(current) do
      Keyword.fetch(current, key)
    else
      :error
    end
  end

  defp fetch_key(_current, _key), do: :error
end
