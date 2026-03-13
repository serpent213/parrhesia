defmodule Parrhesia.ProtocolTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.EventValidator

  test "decodes EVENT frame shape" do
    payload = Jason.encode!(["EVENT", valid_event()])

    assert {:ok, {:event, event}} = Protocol.decode_client(payload)
    assert event["kind"] == 1
    assert event["content"] == "hello"
  end

  test "decodes valid REQ and CLOSE frames" do
    req_payload = Jason.encode!(["REQ", "sub-1", %{"authors" => [String.duplicate("a", 64)]}])
    close_payload = Jason.encode!(["CLOSE", "sub-1"])

    assert {:ok, {:req, "sub-1", [%{"authors" => [_author]}]}} =
             Protocol.decode_client(req_payload)

    assert {:ok, {:close, "sub-1"}} = Protocol.decode_client(close_payload)
  end

  test "rejects invalid subscription ids" do
    empty_sub_payload = Jason.encode!(["REQ", "", %{"kinds" => [1]}])
    long_sub_payload = Jason.encode!(["CLOSE", String.duplicate("x", 65)])

    assert {:error, :invalid_subscription_id} = Protocol.decode_client(empty_sub_payload)
    assert {:error, :invalid_subscription_id} = Protocol.decode_client(long_sub_payload)
  end

  test "returns decode errors for malformed messages" do
    assert {:error, :invalid_json} = Protocol.decode_client("not-json")
    assert {:error, :invalid_filters} = Protocol.decode_client(Jason.encode!(["REQ", "sub-1"]))

    assert {:error, :invalid_event} =
             Protocol.decode_client(Jason.encode!(["EVENT", "not-a-map"]))
  end

  test "validates strict NIP-01 event fields" do
    event = valid_event()
    assert :ok = Protocol.validate_event(event)

    future_event = Map.put(event, "created_at", System.system_time(:second) + 3_600)
    future_event = Map.put(future_event, "id", EventValidator.compute_id(future_event))

    assert {:error, "invalid: event creation date is too far off from the current time"} =
             Protocol.validate_event(future_event)

    mismatched_id_event = Map.put(event, "id", String.duplicate("f", 64))

    assert {:error, "invalid: event id does not match serialized event"} =
             Protocol.validate_event(mismatched_id_event)

    bad_sig_event = Map.put(event, "sig", "abc")

    assert {:error, "invalid: sig must be 64-byte lowercase hex"} =
             Protocol.validate_event(bad_sig_event)
  end

  test "encodes relay messages" do
    frame = Protocol.encode_relay({:closed, "sub-1", "error: subscription closed"})
    assert Jason.decode!(frame) == ["CLOSED", "sub-1", "error: subscription closed"]
  end

  defp valid_event do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [["p", String.duplicate("2", 64)]],
      "content" => "hello",
      "sig" => String.duplicate("3", 128)
    }

    Map.put(base_event, "id", EventValidator.compute_id(base_event))
  end
end
