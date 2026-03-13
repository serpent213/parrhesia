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

  test "rejects direct kind 444 welcome events" do
    event =
      valid_keypackage_event(%{
        "kind" => 444,
        "tags" => [["e", String.duplicate("a", 64)], ["encoding", "base64"]],
        "content" => Base.encode64("welcome")
      })

    assert {:error, :invalid_marmot_direct_welcome_event} = EventValidator.validate(event)

    assert {:error,
            "invalid: kind 444 welcome events must be wrapped in kind 1059 and remain unsigned"} =
             Protocol.validate_event(event)
  end

  test "accepts valid kind 445 Marmot group envelope" do
    group_event =
      valid_keypackage_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("c", 64)]],
        "content" => Base.encode64("mls-message")
      })

    assert :ok = EventValidator.validate(group_event)
  end

  test "accepts opaque binary payload for kind 445 without MLS inspection" do
    opaque_payload = Base.encode64(<<0, 255, 10, 42, 128, 1, 2, 3>>)

    group_event =
      valid_keypackage_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("c", 64)]],
        "content" => opaque_payload
      })

    assert :ok = EventValidator.validate(group_event)
  end

  test "rejects malformed kind 445 Marmot group envelopes" do
    missing_h =
      valid_keypackage_event(%{
        "kind" => 445,
        "tags" => [["p", String.duplicate("c", 64)]],
        "content" => Base.encode64("mls-message")
      })

    invalid_h =
      valid_keypackage_event(%{
        "kind" => 445,
        "tags" => [["h", "not-hex"]],
        "content" => Base.encode64("mls-message")
      })

    invalid_content =
      valid_keypackage_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("d", 64)]],
        "content" => "not-base64"
      })

    assert {:error, :missing_marmot_group_tag} = EventValidator.validate(missing_h)
    assert {:error, :invalid_marmot_group_tag} = EventValidator.validate(invalid_h)
    assert {:error, :invalid_marmot_group_content} = EventValidator.validate(invalid_content)
  end

  test "rejects malformed kind 1059 wrapped welcome envelopes" do
    invalid_missing_recipient =
      valid_keypackage_event(%{
        "kind" => 1059,
        "tags" => [["e", String.duplicate("a", 64)]],
        "content" => "ciphertext"
      })

    invalid_recipient_pubkey =
      valid_keypackage_event(%{
        "kind" => 1059,
        "tags" => [["p", "not-hex"]],
        "content" => "ciphertext"
      })

    invalid_empty_content =
      valid_keypackage_event(%{
        "kind" => 1059,
        "tags" => [["p", String.duplicate("b", 64)]],
        "content" => ""
      })

    assert {:error, :missing_giftwrap_recipient_tag} =
             EventValidator.validate(invalid_missing_recipient)

    assert {:error, :invalid_giftwrap_recipient_tag} =
             EventValidator.validate(invalid_recipient_pubkey)

    assert {:error, :invalid_giftwrap_content} =
             EventValidator.validate(invalid_empty_content)
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
