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
      event = %{
        "pubkey" => author,
        "kind" => 1,
        "created_at" => created_at,
        "tags" => [],
        "content" => ""
      }

      filter = %{"authors" => candidate_authors}

      assert Filter.matches_filter?(event, filter) == author in candidate_authors
    end
  end

  defp hex64 do
    StreamData.binary(length: 32)
    |> StreamData.map(&Base.encode16(&1, case: :lower))
  end
end
