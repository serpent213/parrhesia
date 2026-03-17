defmodule Parrhesia.Storage.Adapters.Postgres.EventsTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Storage.Adapters.Postgres.Events

  test "normalize_event/1 decodes hex fields and extracts d_tag/expiration" do
    pubkey = String.duplicate("a", 64)

    event = %{
      "pubkey" => pubkey,
      "created_at" => 1_700_000_000,
      "kind" => 30_023,
      "tags" => [["d", "profile"], ["expiration", "1700001000"], ["p", String.duplicate("b", 64)]],
      "content" => "hello",
      "sig" => String.duplicate("c", 128)
    }

    id = EventValidator.compute_id(event)
    event = Map.put(event, "id", id)

    assert {:ok, normalized} = Events.normalize_event(event)
    assert normalized.created_at == 1_700_000_000
    assert normalized.kind == 30_023
    assert normalized.d_tag == "profile"
    assert normalized.expires_at == 1_700_001_000
    assert normalized.id == Base.decode16!(id, case: :lower)
    assert normalized.pubkey == Base.decode16!(pubkey, case: :lower)
  end

  test "applies MLS retention TTL to kind 445" do
    previous_policies = Application.get_env(:parrhesia, :policies, [])

    Application.put_env(
      :parrhesia,
      :policies,
      Keyword.put(previous_policies, :mls_group_event_ttl_seconds, 120)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :policies, previous_policies)
    end)

    event = %{
      "id" => String.duplicate("1", 64),
      "pubkey" => String.duplicate("2", 64),
      "created_at" => 1_700_000_000,
      "kind" => 445,
      "tags" => [],
      "content" => "mls",
      "sig" => String.duplicate("3", 128)
    }

    assert {:ok, normalized} = Events.normalize_event(event)
    assert normalized.expires_at == 1_700_000_120
  end

  test "keeps explicit expiration tag for kind 445 when present" do
    previous_policies = Application.get_env(:parrhesia, :policies, [])

    Application.put_env(
      :parrhesia,
      :policies,
      Keyword.put(previous_policies, :mls_group_event_ttl_seconds, 120)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :policies, previous_policies)
    end)

    event = %{
      "id" => String.duplicate("4", 64),
      "pubkey" => String.duplicate("5", 64),
      "created_at" => 1_700_000_000,
      "kind" => 445,
      "tags" => [["expiration", "1700000900"]],
      "content" => "mls",
      "sig" => String.duplicate("6", 128)
    }

    assert {:ok, normalized} = Events.normalize_event(event)
    assert normalized.expires_at == 1_700_000_900
  end

  test "candidate_wins_state?/2 uses created_at then lexical id tie-break" do
    assert Events.candidate_wins_state?(
             %{created_at: 11, id: <<2>>},
             %{event_created_at: 10, event_id: <<255>>}
           )

    refute Events.candidate_wins_state?(
             %{created_at: 9, id: <<0>>},
             %{event_created_at: 10, event_id: <<255>>}
           )

    assert Events.candidate_wins_state?(
             %{created_at: 10, id: <<1>>},
             %{event_created_at: 10, event_id: <<2>>}
           )

    refute Events.candidate_wins_state?(
             %{created_at: 10, id: <<3>>},
             %{event_created_at: 10, event_id: <<2>>}
           )
  end
end
