defmodule Parrhesia.IntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias ExUnit.Case
  alias Parrhesia.Repo
  alias Parrhesia.TestSupport.Runtime

  using opts do
    quote bind_quoted: [opts: opts] do
      use Case, async: Keyword.get(opts, :async, false)

      alias Ecto.Adapters.SQL.Sandbox
      alias Parrhesia.Repo

      @moduletag parrhesia_sandbox: Keyword.get(opts, :sandbox, false)
    end
  end

  setup tags do
    Runtime.ensure_started!()

    case tags[:parrhesia_sandbox] do
      false ->
        :ok

      true ->
        :ok = Sandbox.checkout(Repo)

      :shared ->
        :ok = Sandbox.checkout(Repo)
        Sandbox.mode(Repo, {:shared, self()})

        on_exit(fn ->
          Sandbox.mode(Repo, :manual)
        end)
    end

    :ok
  end
end
