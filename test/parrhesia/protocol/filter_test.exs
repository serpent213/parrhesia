defmodule Parrhesia.Protocol.FilterTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Protocol.Filter

  test "validates a supported filter set" do
    filters = [
      %{
        "ids" => [String.duplicate("a", 64)],
        "authors" => [String.duplicate("b", 64)],
        "kinds" => [1, 3_000],
        "since" => 1_700_000_000,
        "until" => 1_900_000_000,
        "limit" => 100,
        "#p" => [String.duplicate("c", 64)]
      }
    ]

    assert :ok = Filter.validate_filters(filters)
  end

  test "accepts search filter key and rejects unknown keys" do
    assert :ok = Filter.validate_filters([%{"search" => "hello"}])

    assert {:error, :invalid_filter_key} =
             Filter.validate_filters([%{"unknown" => "value"}])

    assert Filter.error_message(:invalid_filter_key) ==
             "invalid: filter contains unknown elements"
  end

  test "rejects invalid ids/authors/kinds" do
    assert {:error, :invalid_ids} = Filter.validate_filters([%{"ids" => ["abc"]}])

    assert {:error, :invalid_authors} =
             Filter.validate_filters([%{"authors" => [String.duplicate("A", 64)]}])

    assert {:error, :invalid_kinds} = Filter.validate_filters([%{"kinds" => ["1"]}])
    assert {:error, :invalid_search} = Filter.validate_filters([%{"search" => ""}])
  end

  test "matches with AND semantics inside filter and OR across filters" do
    event = valid_event()

    matching_filter = %{
      "authors" => [event["pubkey"]],
      "kinds" => [event["kind"]],
      "#e" => ["ref-2"],
      "since" => event["created_at"],
      "until" => event["created_at"],
      "search" => "HEL"
    }

    non_matching_filter = %{"authors" => [String.duplicate("d", 64)]}

    assert Filter.matches_filter?(event, matching_filter)
    refute Filter.matches_filter?(event, non_matching_filter)

    assert Filter.matches_any?(event, [non_matching_filter, matching_filter])
    refute Filter.matches_any?(event, [non_matching_filter])
  end

  test "rejects when req includes more filters than allowed" do
    filters = Enum.map(1..17, fn _ -> %{"kinds" => [1]} end)

    assert {:error, :too_many_filters} = Filter.validate_filters(filters)
  end

  defp valid_event do
    created_at = System.system_time(:second)

    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => created_at,
      "kind" => 1,
      "tags" => [["e", "ref-1"], ["e", "ref-2"], ["p", String.duplicate("2", 64)]],
      "content" => "hello",
      "sig" => String.duplicate("3", 128)
    }

    Map.put(base_event, "id", EventValidator.compute_id(base_event))
  end
end
