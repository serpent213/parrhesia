defmodule Parrhesia.Web.ConnectionTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Web.Connection

  test "REQ registers subscription and replies with EOSE" do
    {:ok, state} = Connection.init(%{})

    req_payload = Jason.encode!(["REQ", "sub-123", %{"kinds" => [1]}])

    assert {:push, {:text, response}, next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    assert MapSet.member?(next_state.subscriptions, "sub-123")
    assert Jason.decode!(response) == ["EOSE", "sub-123"]
  end

  test "CLOSE removes subscription and replies with CLOSED" do
    {:ok, state} = Connection.init(%{})

    req_payload = Jason.encode!(["REQ", "sub-123", %{"kinds" => [1]}])
    {:push, _, subscribed_state} = Connection.handle_in({req_payload, [opcode: :text]}, state)

    close_payload = Jason.encode!(["CLOSE", "sub-123"])

    assert {:push, {:text, response}, next_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, subscribed_state)

    refute MapSet.member?(next_state.subscriptions, "sub-123")
    assert Jason.decode!(response) == ["CLOSED", "sub-123", "closed: subscription closed"]
  end

  test "invalid input returns NOTICE" do
    {:ok, state} = Connection.init(%{})

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({"not-json", [opcode: :text]}, state)

    assert Jason.decode!(response) == ["NOTICE", "error:invalid: malformed JSON"]
  end

  test "EVENT currently replies with unsupported OK" do
    {:ok, state} = Connection.init(%{})

    payload =
      Jason.encode!([
        "EVENT",
        %{
          "id" => String.duplicate("0", 64),
          "pubkey" => String.duplicate("1", 64),
          "created_at" => 1_715_000_000,
          "kind" => 1,
          "tags" => [],
          "content" => "hello",
          "sig" => String.duplicate("3", 128)
        }
      ])

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert Jason.decode!(response) == [
             "OK",
             String.duplicate("0", 64),
             false,
             "error:unsupported: EVENT ingest not implemented"
           ]
  end
end
