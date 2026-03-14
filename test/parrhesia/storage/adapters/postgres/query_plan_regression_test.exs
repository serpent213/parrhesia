defmodule Parrhesia.Storage.Adapters.Postgres.QueryPlanRegressionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Adapters.Postgres.Events

  setup_all do
    if is_nil(Process.whereis(Repo)) do
      start_supervised!(Repo)
    end

    Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = Repo.query!("SET enable_seqscan TO off") |> then(fn _ -> :ok end)
  end

  test "#h-heavy query plan uses dedicated event_tags h index" do
    group_id = String.duplicate("a", 64)

    Enum.each(1..150, fn idx ->
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_010_000 + idx,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("group-#{idx}")
      })
    end)

    Enum.each(1..50, fn idx ->
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_020_000 + idx,
        "tags" => [["h", String.duplicate("b", 64)]],
        "content" => Base.encode64("other-#{idx}")
      })
    end)

    explain =
      Repo.query!(
        """
        EXPLAIN (FORMAT TEXT)
        SELECT e.id
        FROM events e
        WHERE e.kind = 445
          AND e.deleted_at IS NULL
          AND EXISTS (
            SELECT 1
            FROM event_tags t
            WHERE t.event_created_at = e.created_at
              AND t.event_id = e.id
              AND t.name = 'h'
              AND t.value = $1
          )
        ORDER BY e.created_at DESC, e.id ASC
        LIMIT 100
        """,
        [group_id]
      )

    plan = Enum.map_join(explain.rows, "\n", &hd/1)
    assert plan =~ "Index Scan using event_tags_"
    refute plan =~ "Filter: ((name)::text = 'h'::text)"
  end

  test "#i-heavy query plan uses dedicated event_tags i index" do
    keypackage_ref = String.duplicate("c", 64)

    Enum.each(1..120, fn idx ->
      persist_event(%{
        "kind" => 443,
        "created_at" => 1_700_030_000 + idx,
        "tags" => [["i", keypackage_ref], ["encoding", "base64"]],
        "content" => Base.encode64("keypackage-#{idx}")
      })
    end)

    Enum.each(1..40, fn idx ->
      persist_event(%{
        "kind" => 443,
        "created_at" => 1_700_040_000 + idx,
        "tags" => [["i", String.duplicate("d", 64)], ["encoding", "base64"]],
        "content" => Base.encode64("other-#{idx}")
      })
    end)

    explain =
      Repo.query!(
        """
        EXPLAIN (FORMAT TEXT)
        SELECT e.id
        FROM events e
        WHERE e.kind = 443
          AND e.deleted_at IS NULL
          AND EXISTS (
            SELECT 1
            FROM event_tags t
            WHERE t.event_created_at = e.created_at
              AND t.event_id = e.id
              AND t.name = 'i'
              AND t.value = $1
          )
        ORDER BY e.created_at DESC, e.id ASC
        LIMIT 100
        """,
        [keypackage_ref]
      )

    plan = Enum.map_join(explain.rows, "\n", &hd/1)
    assert plan =~ "Index Scan using event_tags_"
    refute plan =~ "Filter: ((name)::text = 'i'::text)"
  end

  defp persist_event(overrides) do
    event = build_event(overrides)
    assert {:ok, _persisted} = Events.put_event(%{}, event)
  end

  defp build_event(overrides) do
    base_event = %{
      "pubkey" => String.duplicate("7", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "query-plan-#{System.unique_integer([:positive])}",
      "sig" => String.duplicate("8", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
