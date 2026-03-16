defmodule Parrhesia.Auth.Nip98Test do
  use ExUnit.Case, async: true

  alias Parrhesia.Auth.Nip98
  alias Parrhesia.Protocol.EventValidator

  test "validates authorization header with matching method and url tags" do
    url = "http://example.com/management"
    event = nip98_event("POST", url)
    header = "Nostr " <> Base.encode64(JSON.encode!(event))

    assert {:ok, parsed_event} = Nip98.validate_authorization_header(header, "POST", url)
    assert parsed_event["id"] == event["id"]
  end

  test "rejects mismatched method and url" do
    url = "http://example.com/management"
    event = nip98_event("POST", url)
    header = "Nostr " <> Base.encode64(JSON.encode!(event))

    assert {:error, :invalid_method_tag} =
             Nip98.validate_authorization_header(header, "GET", url)

    assert {:error, :invalid_url_tag} =
             Nip98.validate_authorization_header(header, "POST", "http://example.com/other")
  end

  test "supports overriding the freshness window" do
    url = "http://example.com/management"
    event = nip98_event("POST", url, %{"created_at" => System.system_time(:second) - 120})
    header = "Nostr " <> Base.encode64(JSON.encode!(event))

    assert {:error, :stale_event} = Nip98.validate_authorization_header(header, "POST", url)

    assert {:ok, _event} =
             Nip98.validate_authorization_header(header, "POST", url, max_age_seconds: 180)
  end

  defp nip98_event(method, url, overrides \\ %{}) do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("a", 64),
      "created_at" => now,
      "kind" => 27_235,
      "tags" => [["method", method], ["u", url]],
      "content" => "",
      "sig" => String.duplicate("b", 128)
    }

    event = Map.merge(base, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
