defmodule Parrhesia.Protocol.EventValidatorMarmotTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.EventValidator

  test "accepts valid MIP-00 keypackage envelope (kind 443)" do
    event = valid_keypackage_event()

    assert :ok = EventValidator.validate(event)
    assert :ok = Protocol.validate_event(event)
  end

  test "rejects keypackage without required encoding tag" do
    event =
      valid_keypackage_event(%{
        "tags" =>
          Enum.reject(valid_keypackage_tags(), fn [name | _rest] -> name == "encoding" end)
      })

    assert {:error, :missing_marmot_encoding_tag} = EventValidator.validate(event)

    assert {:error, "invalid: kind 443 must include [\"encoding\", \"base64\"]"} =
             Protocol.validate_event(event)
  end

  test "rejects keypackage with non-base64 content" do
    event = valid_keypackage_event(%{"content" => "%%%not-base64%%%"})

    assert {:error, :invalid_marmot_keypackage_content} = EventValidator.validate(event)
  end

  test "accepts keypackage relay list envelope (kind 10051)" do
    event = valid_keypackage_relay_list_event()

    assert :ok = EventValidator.validate(event)
  end

  test "rejects keypackage relay list without relay tags" do
    event = valid_keypackage_relay_list_event(%{"tags" => [["p", String.duplicate("f", 64)]]})

    assert {:error, :missing_marmot_relay_tag} = EventValidator.validate(event)
  end

  defp valid_keypackage_event(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 443,
      "tags" => valid_keypackage_tags(),
      "content" => Base.encode64("fake-keypackage-bundle"),
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end

  defp valid_keypackage_tags do
    [
      ["mls_protocol_version", "1.0"],
      ["mls_ciphersuite", "0x0001"],
      ["mls_extensions", "0xf2ee", "0x000a"],
      ["encoding", "base64"],
      ["i", String.duplicate("a", 64)],
      ["relays", "wss://relay.example.com"]
    ]
  end

  defp valid_keypackage_relay_list_event(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("3", 64),
      "created_at" => System.system_time(:second),
      "kind" => 10_051,
      "tags" => [["relay", "wss://relay.one"], ["relay", "wss://relay.two"]],
      "content" => "",
      "sig" => String.duplicate("4", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
