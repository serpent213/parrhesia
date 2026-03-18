defmodule Parrhesia.PostgresRepos do
  @moduledoc false

  alias Parrhesia.Config
  alias Parrhesia.ReadRepo
  alias Parrhesia.Repo

  @spec write() :: module()
  def write, do: Repo

  @spec read() :: module()
  def read do
    if separate_read_pool_enabled?() and is_pid(Process.whereis(ReadRepo)) do
      ReadRepo
    else
      Repo
    end
  end

  @spec started_repos() :: [module()]
  def started_repos do
    cond do
      not postgres_enabled?() ->
        []

      separate_read_pool_enabled?() ->
        [Repo, ReadRepo]

      true ->
        [Repo]
    end
  end

  @spec postgres_enabled?() :: boolean()
  def postgres_enabled? do
    case Process.whereis(Config) do
      pid when is_pid(pid) ->
        Config.get([:storage, :backend], storage_backend_default()) == :postgres

      nil ->
        storage_backend_default() == :postgres
    end
  end

  @spec separate_read_pool_enabled?() :: boolean()
  def separate_read_pool_enabled? do
    case {postgres_enabled?(), Process.whereis(Config)} do
      {false, _pid} ->
        false

      {true, pid} when is_pid(pid) ->
        Config.get(
          [:database, :separate_read_pool?],
          application_default(:separate_read_pool?, false)
        )

      {true, nil} ->
        application_default(:separate_read_pool?, false)
    end
  end

  defp application_default(key, default) do
    :parrhesia
    |> Application.get_env(:database, [])
    |> Keyword.get(key, default)
  end

  defp storage_backend_default do
    :parrhesia
    |> Application.get_env(:storage, [])
    |> Keyword.get(:backend, :postgres)
  end
end
