defmodule Parrhesia.Protocol.EventValidatorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Parrhesia.Protocol.EventValidator

  property "compute_id always returns lowercase 64-char hex" do
    check all(event <- event_payload()) do
      id = EventValidator.compute_id(event)

      assert byte_size(id) == 64
      assert {:ok, _decoded} = Base.decode16(id, case: :lower)
    end
  end

  property "compute_id depends only on the canonical NIP-01 tuple fields" do
    check all(
            event <- event_payload(),
            replacement_id <- hex64(),
            replacement_sig <- hex128(),
            extra_value <- StreamData.string(:alphanumeric)
          ) do
      original = EventValidator.compute_id(event)

      mutated_event =
        event
        |> Map.put("id", replacement_id)
        |> Map.put("sig", replacement_sig)
        |> Map.put("extra_field", extra_value)

      assert EventValidator.compute_id(mutated_event) == original
    end
  end

  defp event_payload do
    gen all(
          pubkey <- hex64(),
          created_at <- StreamData.non_negative_integer(),
          kind <- StreamData.integer(0..65_535),
          tags <- tags(),
          content <- StreamData.string(:printable, max_length: 256),
          sig <- hex128(),
          id <- hex64()
        ) do
      %{
        "id" => id,
        "pubkey" => pubkey,
        "created_at" => created_at,
        "kind" => kind,
        "tags" => tags,
        "content" => content,
        "sig" => sig
      }
    end
  end

  defp tags do
    StreamData.list_of(tag(), max_length: 8)
  end

  defp tag do
    StreamData.list_of(StreamData.string(:printable, min_length: 1, max_length: 32),
      min_length: 1,
      max_length: 4
    )
  end

  defp hex64 do
    StreamData.binary(length: 32)
    |> StreamData.map(&Base.encode16(&1, case: :lower))
  end

  defp hex128 do
    StreamData.binary(length: 64)
    |> StreamData.map(&Base.encode16(&1, case: :lower))
  end
end
