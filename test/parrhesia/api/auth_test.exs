defmodule Parrhesia.API.AuthTest do
  use ExUnit.Case, async: true

  alias Parrhesia.API.Auth
  alias Parrhesia.Protocol.EventValidator

  test "validate_event delegates to event validation" do
    assert {:error, :invalid_shape} = Auth.validate_event(%{})
  end

  test "compute_event_id matches the protocol event validator" do
    event = %{
      "pubkey" => String.duplicate("a", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "hello",
      "sig" => String.duplicate("b", 128)
    }

    assert Auth.compute_event_id(event) == EventValidator.compute_id(event)
  end

  test "validate_nip98 returns shared auth context" do
    url = "http://example.com/management"
    event = nip98_event("POST", url)
    header = "Nostr " <> Base.encode64(JSON.encode!(event))

    assert {:ok, auth_context} = Auth.validate_nip98(header, "POST", url)
    assert auth_context.pubkey == event["pubkey"]
    assert auth_context.auth_event["id"] == event["id"]
    assert auth_context.request_context.caller == :http
    assert MapSet.member?(auth_context.request_context.authenticated_pubkeys, event["pubkey"])
    assert auth_context.metadata == %{method: "POST", url: url}
  end

  test "validate_nip98 accepts custom freshness window" do
    url = "http://example.com/management"
    event = nip98_event("POST", url, %{"created_at" => System.system_time(:second) - 120})
    header = "Nostr " <> Base.encode64(JSON.encode!(event))

    assert {:error, :stale_event} = Auth.validate_nip98(header, "POST", url)
    assert {:ok, _context} = Auth.validate_nip98(header, "POST", url, max_age_seconds: 180)
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

    base
    |> Map.merge(overrides)
    |> Map.put("id", EventValidator.compute_id(Map.merge(base, overrides)))
  end
end
