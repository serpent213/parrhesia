defmodule Parrhesia.Web.Readiness do
  @moduledoc false

  alias Parrhesia.PostgresRepos

  @spec ready?() :: boolean()
  def ready? do
    process_ready?(Parrhesia.Subscriptions.Index) and
      process_ready?(Parrhesia.Auth.Challenges) and
      negentropy_ready?() and
      repos_ready?()
  end

  defp negentropy_ready? do
    if negentropy_enabled?() do
      process_ready?(Parrhesia.Negentropy.Sessions)
    else
      true
    end
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end

  defp process_ready?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> true
      nil -> false
    end
  end

  defp repos_ready? do
    Enum.all?(PostgresRepos.started_repos(), &process_ready?/1)
  end
end
