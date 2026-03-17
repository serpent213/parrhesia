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
        # Delegate sandbox ownership to a dedicated process that outlives
        # the test process. ExUnit terminates start_supervised! children
        # (in reverse start order) before running on_exit callbacks. With
        # the test process as sandbox owner, the connection dies the
        # moment the test process exits — supervised children that make
        # DB calls during their shutdown sequence would hit a dead
        # connection. The separate owner stays alive through the entire
        # supervised-child shutdown, and is only stopped in on_exit
        # (which runs afterwards).
        test_pid = self()

        owner =
          spawn(fn ->
            :ok = Sandbox.checkout(Repo)
            send(test_pid, {:sandbox_ready, self()})

            receive do
              :stop ->
                Sandbox.checkin(Repo)
            end
          end)

        receive do
          {:sandbox_ready, ^owner} -> :ok
        after
          5_000 -> raise "Sandbox owner checkout timed out"
        end

        Sandbox.mode(Repo, {:shared, owner})

        on_exit(fn ->
          ref = Process.monitor(owner)
          send(owner, :stop)

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
          after
            5_000 -> :ok
          end

          Sandbox.mode(Repo, :manual)
        end)
    end

    :ok
  end
end
