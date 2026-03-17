defmodule Parrhesia.Negentropy.SessionsTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Negentropy.Engine
  alias Parrhesia.Negentropy.Message
  alias Parrhesia.Negentropy.Sessions
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Adapters.Postgres.Events

  test "opens, responds, advances and closes sessions" do
    server = start_supervised!({Sessions, name: nil})
    Sandbox.allow(Repo, self(), server)

    first =
      persist_event(%{
        "created_at" => 1_700_100_000,
        "content" => "neg-1"
      })

    second =
      persist_event(%{
        "created_at" => 1_700_100_001,
        "content" => "neg-2"
      })

    initial_message = Engine.initial_message([])

    assert {:ok, response_message} =
             Sessions.open(server, self(), "sub-neg", %{"kinds" => [1]}, initial_message)

    assert {:ok, [%{mode: :id_list, payload: ids, upper_bound: :infinity}]} =
             Message.decode(response_message)

    assert ids == [
             Base.decode16!(first["id"], case: :mixed),
             Base.decode16!(second["id"], case: :mixed)
           ]

    {:ok, refs} = Events.query_event_refs(%{}, [%{"kinds" => [1]}], [])
    matching_message = Engine.initial_message(refs)

    assert {:ok, <<0x61>>} = Sessions.message(server, self(), "sub-neg", matching_message)

    assert :ok = Sessions.close(server, self(), "sub-neg")
    assert {:error, :unknown_session} = Sessions.message(server, self(), "sub-neg", <<0x61>>)
  end

  test "rejects oversized NEG payloads" do
    server =
      start_supervised!(
        {Sessions,
         name: nil,
         max_payload_bytes: 32,
         max_sessions_per_owner: 8,
         max_total_sessions: 16,
         max_idle_seconds: 60,
         sweep_interval_seconds: 60}
      )

    Sandbox.allow(Repo, self(), server)

    assert {:error, :payload_too_large} =
             Sessions.open(
               server,
               self(),
               "sub-neg",
               %{"kinds" => [1]},
               String.duplicate(<<0x61>>, 128)
             )
  end

  test "enforces per-owner session limits" do
    server =
      start_supervised!(
        {Sessions,
         name: nil,
         max_payload_bytes: 1024,
         max_sessions_per_owner: 1,
         max_total_sessions: 16,
         max_idle_seconds: 60,
         sweep_interval_seconds: 60}
      )

    Sandbox.allow(Repo, self(), server)

    assert {:ok, _response} =
             Sessions.open(server, self(), "sub-1", %{"kinds" => [1]}, Engine.initial_message([]))

    assert {:error, :owner_session_limit_reached} =
             Sessions.open(server, self(), "sub-2", %{"kinds" => [1]}, Engine.initial_message([]))
  end

  test "blocks queries larger than the configured session snapshot limit" do
    server =
      start_supervised!(
        {Sessions,
         name: nil,
         max_payload_bytes: 1024,
         max_sessions_per_owner: 8,
         max_total_sessions: 16,
         max_idle_seconds: 60,
         sweep_interval_seconds: 60,
         max_items_per_session: 1}
      )

    Sandbox.allow(Repo, self(), server)

    persist_event(%{"created_at" => 1_700_200_000, "content" => "first"})
    persist_event(%{"created_at" => 1_700_200_001, "content" => "second"})

    assert {:error, :query_too_big} =
             Sessions.open(
               server,
               self(),
               "sub-neg",
               %{"kinds" => [1]},
               Engine.initial_message([])
             )
  end

  defp persist_event(overrides) do
    event = build_event(overrides)
    assert {:ok, persisted_event} = Events.put_event(%{}, event)
    persisted_event
  end

  defp build_event(overrides) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "negentropy-test",
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
