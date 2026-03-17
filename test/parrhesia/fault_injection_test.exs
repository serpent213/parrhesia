defmodule Parrhesia.FaultInjectionTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Web.Connection

  alias Parrhesia.TestSupport.FailingEvents
  alias Parrhesia.TestSupport.PermissiveModeration

  setup do
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

    :ok
  end

  test "EVENT responds with error prefix when storage is unavailable" do
    {:ok, state} = Connection.init(subscription_index: nil)
    event = valid_event()

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({JSON.encode!(["EVENT", event]), [opcode: :text]}, state)

    assert JSON.decode!(response) == ["OK", event["id"], false, "error: :db_down"]
  end

  test "REQ closes with storage error when query fails" do
    {:ok, state} = Connection.init(subscription_index: nil)
    payload = JSON.encode!(["REQ", "sub-db-down", %{"kinds" => [1]}])

    assert {:push, {:text, response}, ^state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == ["CLOSED", "sub-db-down", "error: :db_down"]
  end

  defp valid_event do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => now,
      "kind" => 1,
      "tags" => [],
      "content" => "fault",
      "sig" => String.duplicate("2", 128)
    }

    Map.put(base, "id", EventValidator.compute_id(base))
  end
end
