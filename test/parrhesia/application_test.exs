defmodule Parrhesia.ApplicationTest do
  use Parrhesia.IntegrationCase, async: false

  test "starts the core supervision tree" do
    assert is_pid(Process.whereis(Parrhesia.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Telemetry))
    assert is_pid(Process.whereis(Parrhesia.Config))
    assert is_pid(Process.whereis(Parrhesia.Web.EventIngestLimiter))
    assert is_pid(Process.whereis(Parrhesia.Storage.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Subscriptions.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Auth.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Sync.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Policy.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Web.Endpoint))
    assert is_pid(Process.whereis(Parrhesia.Tasks.Supervisor))

    assert Enum.any?(Supervisor.which_children(Parrhesia.Web.Endpoint), fn {_id, pid, _type,
                                                                            modules} ->
             is_pid(pid) and modules == [Bandit]
           end)

    assert is_pid(Process.whereis(Parrhesia.Auth.Challenges))
    assert is_pid(Process.whereis(Parrhesia.Auth.Nip98ReplayCache))
    assert is_pid(Process.whereis(Parrhesia.API.Identity.Manager))
    assert is_pid(Process.whereis(Parrhesia.API.Sync.Manager))

    if negentropy_enabled?() do
      assert is_pid(Process.whereis(Parrhesia.Negentropy.Sessions))
    end
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end
end
