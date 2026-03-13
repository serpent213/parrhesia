defmodule Parrhesia.ProtocolTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol

  test "decodes valid EVENT frame" do
    payload =
      Jason.encode!([
        "EVENT",
        %{
          "id" => String.duplicate("0", 64),
          "pubkey" => String.duplicate("1", 64),
          "created_at" => 1_715_000_000,
          "kind" => 1,
          "tags" => [["p", String.duplicate("2", 64)]],
          "content" => "hello",
          "sig" => String.duplicate("3", 128)
        }
      ])

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

  test "returns decode errors for malformed messages" do
    assert {:error, :invalid_json} = Protocol.decode_client("not-json")
    assert {:error, :invalid_filters} = Protocol.decode_client(Jason.encode!(["REQ", "sub-1"]))

    assert {:error, :invalid_event} =
             Protocol.decode_client(Jason.encode!(["EVENT", %{"id" => "nope"}]))
  end

  test "encodes relay messages" do
    frame = Protocol.encode_relay({:closed, "sub-1", "closed: subscription closed"})
    assert Jason.decode!(frame) == ["CLOSED", "sub-1", "closed: subscription closed"]
  end
end
