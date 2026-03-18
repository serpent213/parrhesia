defmodule Parrhesia.HTTPTest do
  use ExUnit.Case, async: true

  alias Parrhesia.HTTP
  alias Parrhesia.Metadata

  test "default headers advertise the configured user agent" do
    assert Metadata.hide_version?() == true
    assert HTTP.default_headers() == [{"user-agent", Metadata.user_agent()}]
  end

  test "default headers are added without overriding request-specific headers" do
    options =
      HTTP.put_default_headers(
        headers: [{"accept", "application/nostr+json"}],
        decode_body: false
      )

    assert Keyword.get(options, :headers) == [
             {"accept", "application/nostr+json"},
             {"user-agent", Metadata.user_agent()}
           ]

    assert Keyword.get(options, :decode_body) == false
  end

  test "explicit user-agent overrides suppress the default case-insensitively" do
    options = HTTP.put_default_headers(headers: [{"User-Agent", "custom-agent"}])

    assert Keyword.get(options, :headers) == [{"User-Agent", "custom-agent"}]
  end
end
