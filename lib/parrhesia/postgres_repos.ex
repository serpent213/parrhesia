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
    if separate_read_pool_enabled?() do
      [Repo, ReadRepo]
    else
      [Repo]
    end
  end

  @spec separate_read_pool_enabled?() :: boolean()
  def separate_read_pool_enabled? do
    case Process.whereis(Config) do
      pid when is_pid(pid) ->
        Config.get([:database, :separate_read_pool?], application_default())

      nil ->
        application_default()
    end
  end

  defp application_default do
    :parrhesia
    |> Application.get_env(:database, [])
    |> Keyword.get(:separate_read_pool?, false)
  end
end
