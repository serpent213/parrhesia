defmodule Parrhesia.Protocol.EventValidatorNip66Test do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol.EventValidator

  test "accepts valid kind 30166 relay discovery events" do
    event = valid_discovery_event()

    assert :ok = EventValidator.validate(event)
  end

  test "rejects kind 30166 discovery events without d tags" do
    event = valid_discovery_event(%{"tags" => [["N", "11"]]})

    assert {:error, :missing_nip66_d_tag} = EventValidator.validate(event)
  end

  test "accepts valid kind 10166 monitor announcements" do
    event = valid_monitor_announcement()

    assert :ok = EventValidator.validate(event)
  end

  test "rejects kind 10166 monitor announcements without frequency tags" do
    event = valid_monitor_announcement(%{"tags" => [["c", "open"]]})

    assert {:error, :missing_nip66_frequency_tag} = EventValidator.validate(event)
  end

  defp valid_discovery_event(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 30_166,
      "tags" => [
        ["d", "wss://relay.example.com/relay"],
        ["n", "clearnet"],
        ["N", "11"],
        ["R", "!payment"],
        ["R", "auth"],
        ["t", "marmot"],
        ["rtt-open", "12"]
      ],
      "content" => "{}",
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end

  defp valid_monitor_announcement(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("3", 64),
      "created_at" => System.system_time(:second),
      "kind" => 10_166,
      "tags" => [
        ["frequency", "900"],
        ["timeout", "open", "5000"],
        ["c", "open"],
        ["c", "nip11"]
      ],
      "content" => "",
      "sig" => String.duplicate("4", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
