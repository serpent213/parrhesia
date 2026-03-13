defmodule Parrhesia.Web.ConnectionTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol.EventValidator
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
    assert Jason.decode!(response) == ["CLOSED", "sub-123", "error: subscription closed"]
  end

  test "invalid input returns NOTICE" do
    {:ok, state} = Connection.init(%{})

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({"not-json", [opcode: :text]}, state)

    assert Jason.decode!(response) == ["NOTICE", "invalid: malformed JSON"]
  end

  test "REQ with invalid filter returns CLOSED and does not subscribe" do
    {:ok, state} = Connection.init(%{})

    req_payload = Jason.encode!(["REQ", "sub-123", %{"kinds" => ["1"]}])

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    assert Jason.decode!(response) == [
             "CLOSED",
             "sub-123",
             "invalid: kinds must be a non-empty array of integers between 0 and 65535"
           ]
  end

  test "valid EVENT currently replies with unsupported OK" do
    {:ok, state} = Connection.init(%{})

    event = valid_event()
    payload = Jason.encode!(["EVENT", event])

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert Jason.decode!(response) == [
             "OK",
             event["id"],
             false,
             "error: EVENT ingest not implemented"
           ]
  end

  test "invalid EVENT replies with OK false invalid prefix" do
    {:ok, state} = Connection.init(%{})

    event = valid_event() |> Map.put("sig", "nope")
    payload = Jason.encode!(["EVENT", event])

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert Jason.decode!(response) == [
             "OK",
             event["id"],
             false,
             "invalid: sig must be 64-byte lowercase hex"
           ]
  end

  defp valid_event do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "hello",
      "sig" => String.duplicate("3", 128)
    }

    Map.put(base_event, "id", EventValidator.compute_id(base_event))
  end
end
