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

  test "rejects oversized NEG payloads" do
    server =
      start_supervised!(
        {Sessions,
         name: nil,
         max_payload_bytes: 32,
         max_sessions_per_owner: 8,
         max_total_sessions: 16,
         max_idle_seconds: 60,
         sweep_interval_seconds: 60}
      )

    assert {:error, :payload_too_large} =
             Sessions.open(server, self(), "sub-neg", %{"delta" => String.duplicate("a", 256)})
  end

  test "enforces per-owner session limits" do
    server =
      start_supervised!(
        {Sessions,
         name: nil,
         max_payload_bytes: 1024,
         max_sessions_per_owner: 1,
         max_total_sessions: 16,
         max_idle_seconds: 60,
         sweep_interval_seconds: 60}
      )

    assert {:ok, %{"status" => "open", "cursor" => 0}} =
             Sessions.open(server, self(), "sub-1", %{})

    assert {:error, :owner_session_limit_reached} =
             Sessions.open(server, self(), "sub-2", %{})
  end
end
