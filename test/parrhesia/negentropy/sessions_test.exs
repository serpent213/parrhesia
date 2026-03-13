defmodule Parrhesia.Negentropy.SessionsTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Negentropy.Sessions

  test "opens, advances and closes sessions" do
    server = start_supervised!({Sessions, name: nil})

    assert {:ok, %{"status" => "open", "cursor" => 0}} =
             Sessions.open(server, self(), "sub-neg", %{"cursor" => 0})

    assert {:ok, %{"status" => "ack", "cursor" => 1}} =
             Sessions.message(server, self(), "sub-neg", %{"delta" => "abc"})

    assert :ok = Sessions.close(server, self(), "sub-neg")
    assert {:error, :unknown_session} = Sessions.message(server, self(), "sub-neg", %{})
  end
end
