defmodule Parrhesia.Protocol.FilterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Parrhesia.Protocol.Filter

  property "author filter match is equivalent to membership in author list" do
    check all(
            author <- hex64(),
            candidate_authors <- list_of(hex64(), min_length: 1, max_length: 5),
            created_at <- StreamData.non_negative_integer()
          ) do
      event = base_event(author, created_at)
      filter = %{"authors" => candidate_authors}

      assert Filter.matches_filter?(event, filter) == author in candidate_authors
    end
  end

  property "since and until filters follow timestamp boundaries" do
    check all(
            author <- hex64(),
            created_at <- StreamData.non_negative_integer(),
            since <- StreamData.non_negative_integer(),
            until <- StreamData.non_negative_integer()
          ) do
      event = base_event(author, created_at)

      assert Filter.matches_filter?(event, %{"since" => since}) == created_at >= since
      assert Filter.matches_filter?(event, %{"until" => until}) == created_at <= until
    end
  end

  property "tag filters match when any configured value is present on the event" do
    check all(
            author <- hex64(),
            created_at <- StreamData.non_negative_integer(),
            tag_value <- short_string(),
            extra_values <- list_of(short_string(), min_length: 1, max_length: 5)
          ) do
      event =
        base_event(author, created_at)
        |> Map.put("tags", [["e", tag_value]])

      matching_filter = %{"#e" => Enum.uniq([tag_value | extra_values])}
      non_matching_filter = %{"#e" => Enum.map(extra_values, &("nomatch:" <> &1))}

      assert Filter.matches_filter?(event, matching_filter)
      refute Filter.matches_filter?(event, non_matching_filter)
    end
  end

  property "invalid tag filters are rejected during matching" do
    check all(
            author <- hex64(),
            created_at <- StreamData.non_negative_integer(),
            invalid_value <- invalid_tag_filter_value()
          ) do
      event = base_event(author, created_at)

      refute Filter.matches_filter?(event, %{"#e" => [invalid_value]})
    end
  end

  defp base_event(author, created_at) do
    %{
      "pubkey" => author,
      "kind" => 1,
      "created_at" => created_at,
      "tags" => [],
      "content" => ""
    }
  end

  defp hex64 do
    StreamData.binary(length: 32)
    |> StreamData.map(&Base.encode16(&1, case: :lower))
  end

  defp short_string do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp invalid_tag_filter_value do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer(), max_length: 2),
      StreamData.list_of(StreamData.integer(), max_length: 2)
    ])
  end
end
