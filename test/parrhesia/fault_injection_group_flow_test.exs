defmodule Parrhesia.FaultInjectionGroupFlowTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage
  alias Parrhesia.TestSupport.FailingEvents
  alias Parrhesia.TestSupport.PermissiveModeration
  alias Parrhesia.Web.Connection

  setup do
    :ok = Sandbox.checkout(Repo)

    previous_storage = Application.get_env(:parrhesia, :storage, [])

    Application.put_env(
      :parrhesia,
      :storage,
      previous_storage
      |> Keyword.put(:events, FailingEvents)
      |> Keyword.put(:moderation, PermissiveModeration)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :storage, previous_storage)
    end)

    %{previous_storage: previous_storage}
  end

  test "kind 445 commit recovers cleanly after storage outage", %{
    previous_storage: previous_storage
  } do
    {:ok, state} = Connection.init(subscription_index: nil)

    group_event =
      build_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("a", 64)]],
        "content" => Base.encode64("commit")
      })

    payload = JSON.encode!(["EVENT", group_event])

    assert {:push, {:text, error_response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(error_response) == ["OK", group_event["id"], false, "error: :db_down"]

    Application.put_env(
      :parrhesia,
      :storage,
      previous_storage |> Keyword.put(:moderation, PermissiveModeration)
    )

    assert {:push, {:text, ok_response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(ok_response) == ["OK", group_event["id"], true, "ok: event stored"]

    assert {:ok, persisted_group_event} = Storage.events().get_event(%{}, group_event["id"])
    assert persisted_group_event["id"] == group_event["id"]
  end

  test "reordered group flow remains deterministic after outage recovery", %{
    previous_storage: previous_storage
  } do
    {:ok, state} = Connection.init(subscription_index: nil)

    group_id = String.duplicate("b", 64)
    now = System.system_time(:second)

    older_event =
      build_event(%{
        "created_at" => now - 10,
        "kind" => 445,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("older")
      })

    newer_event =
      build_event(%{
        "created_at" => now - 5,
        "kind" => 445,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("newer")
      })

    assert {:push, {:text, outage_response}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", older_event]), [opcode: :text]},
               state
             )

    assert JSON.decode!(outage_response) == ["OK", older_event["id"], false, "error: :db_down"]

    Application.put_env(
      :parrhesia,
      :storage,
      previous_storage |> Keyword.put(:moderation, PermissiveModeration)
    )

    assert {:push, {:text, newer_response}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", newer_event]), [opcode: :text]},
               state
             )

    assert JSON.decode!(newer_response) == ["OK", newer_event["id"], true, "ok: event stored"]

    assert {:push, {:text, older_response}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", older_event]), [opcode: :text]},
               state
             )

    assert JSON.decode!(older_response) == ["OK", older_event["id"], true, "ok: event stored"]

    assert {:ok, results} =
             Storage.events().query(
               %{},
               [%{"kinds" => [445], "#h" => [group_id]}],
               now: now + 1
             )

    assert Enum.map(results, & &1["id"]) == [newer_event["id"], older_event["id"]]
  end

  defp build_event(overrides) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "fault-group",
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
