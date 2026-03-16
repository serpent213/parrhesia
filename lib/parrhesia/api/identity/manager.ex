defmodule Parrhesia.API.Identity.Manager do
  @moduledoc false

  use GenServer

  alias Parrhesia.API.Identity

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case Identity.ensure() do
      {:ok, _identity} ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.error("failed to ensure server identity: #{inspect(reason)}")
        {:ok, %{}}
    end
  end
end
