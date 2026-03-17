defmodule Parrhesia.TestSupport.Runtime do
  @moduledoc false

  @required_processes [
    Parrhesia.Supervisor,
    Parrhesia.Config,
    Parrhesia.Repo,
    Parrhesia.Subscriptions.Supervisor,
    Parrhesia.API.Stream.Supervisor,
    Parrhesia.Web.Endpoint
  ]

  def ensure_started! do
    if healthy?() do
      :ok
    else
      restart!()
    end
  end

  defp healthy? do
    Enum.all?(@required_processes, &is_pid(Process.whereis(&1)))
  end

  defp restart! do
    case Application.stop(:parrhesia) do
      :ok -> :ok
      {:error, {:not_started, :parrhesia}} -> :ok
      {:error, {:not_started, _app}} -> :ok
    end

    {:ok, _apps} = Application.ensure_all_started(:parrhesia)
    :ok
  end
end
