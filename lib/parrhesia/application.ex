defmodule Parrhesia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Parrhesia.Runtime.start_link(name: Parrhesia.Supervisor)
  end
end
