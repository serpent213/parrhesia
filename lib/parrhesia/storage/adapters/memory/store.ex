defmodule Parrhesia.Storage.Adapters.Memory.Store do
  @moduledoc false

  use Agent

  @name __MODULE__

  @initial_state %{
    events: %{},
    deleted: MapSet.new(),
    bans: %{pubkeys: MapSet.new(), events: MapSet.new(), ips: MapSet.new()},
    allowed_pubkeys: MapSet.new(),
    groups: %{},
    roles: %{},
    audit_logs: []
  }

  def ensure_started do
    if Process.whereis(@name) do
      :ok
    else
      start_store()
    end
  end

  defp start_store do
    case Agent.start_link(fn -> @initial_state end, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get(fun) do
    :ok = ensure_started()
    Agent.get(@name, fun)
  end

  def update(fun) do
    :ok = ensure_started()
    Agent.update(@name, fun)
  end

  def get_and_update(fun) do
    :ok = ensure_started()
    Agent.get_and_update(@name, fun)
  end
end
