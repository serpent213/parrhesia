defmodule Parrhesia.Release do
  @moduledoc """
  Helpers for running Ecto tasks from a production release.

  Intended for use from a release `eval` command where Mix is not available:

      bin/parrhesia eval "Parrhesia.Release.migrate()"
      bin/parrhesia eval "Parrhesia.Release.rollback(Parrhesia.Repo, 20260101000000)"
  """

  @app :parrhesia

  @doc """
  Runs all pending Ecto migrations for every configured repo.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  @doc """
  Rolls back the given `repo` to the specified migration `version`.
  """
  def rollback(repo, version) when is_atom(repo) and is_integer(version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :down, to: version)
      end)
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
