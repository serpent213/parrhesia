defmodule Parrhesia.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts the core supervision tree" do
    assert is_pid(Process.whereis(Parrhesia.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Telemetry))
    assert is_pid(Process.whereis(Parrhesia.Config))
    assert is_pid(Process.whereis(Parrhesia.Storage.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Subscriptions.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Auth.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Policy.Supervisor))
    assert is_pid(Process.whereis(Parrhesia.Web.Endpoint))
    assert is_pid(Process.whereis(Parrhesia.Tasks.Supervisor))
  end
end
