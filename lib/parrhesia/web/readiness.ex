defmodule Parrhesia.Web.Readiness do
  @moduledoc false

  @spec ready?() :: boolean()
  def ready? do
    process_ready?(Parrhesia.Subscriptions.Index) and
      process_ready?(Parrhesia.Auth.Challenges) and
      process_ready?(Parrhesia.Negentropy.Sessions) and
      process_ready?(Parrhesia.Repo)
  end

  defp process_ready?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> true
      nil -> false
    end
  end
end
