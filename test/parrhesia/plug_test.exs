defmodule Parrhesia.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Parrhesia.Plug

  test "init resolves configured listener id" do
    opts = Plug.init(listener: :public)

    assert is_list(opts)
    assert Keyword.fetch!(opts, :listener).id == :public
  end

  test "init accepts inline listener map" do
    opts =
      Plug.init(
        listener: %{
          id: :host_mount,
          features: %{nostr: %{enabled: true}}
        }
      )

    assert Keyword.fetch!(opts, :listener).id == :host_mount
  end

  test "init raises for unknown listener id" do
    assert_raise ArgumentError, ~r/listener :does_not_exist not found/, fn ->
      Plug.init(listener: :does_not_exist)
    end
  end

  test "call serves health route" do
    opts = Plug.init(listener: :public)

    response =
      conn(:get, "/health")
      |> Plug.call(opts)

    assert response.status == 200
    assert response.resp_body == "ok"
  end
end
