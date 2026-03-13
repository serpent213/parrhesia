defmodule Parrhesia.Web.ConformanceTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage
  alias Parrhesia.Web.Connection

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "REQ -> EOSE emitted once and CLOSE emits CLOSED" do
    {:ok, state} = Connection.init(subscription_index: nil)

    req_payload = Jason.encode!(["REQ", "sub-e2e", %{"kinds" => [1]}])

    assert {:push, frames, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> Jason.decode!(frame) end)
    assert ["EOSE", "sub-e2e"] = List.last(decoded)

    close_payload = Jason.encode!(["CLOSE", "sub-e2e"])

    assert {:push, {:text, closed_frame}, closed_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, subscribed_state)

    assert Jason.decode!(closed_frame) == ["CLOSED", "sub-e2e", "error: subscription closed"]
    refute Map.has_key?(closed_state.subscriptions, "sub-e2e")
  end

  test "EVENT accepted path returns canonical OK frame" do
    {:ok, state} = Connection.init(subscription_index: nil)

    event = valid_event()

    assert {:push, {:text, frame}, ^state} =
             Connection.handle_in({Jason.encode!(["EVENT", event]), [opcode: :text]}, state)

    assert Jason.decode!(frame) == ["OK", event["id"], true, "ok: event stored"]
  end

  test "wrapped kind 1059 welcome delivery is recipient-gated" do
    {:ok, state} = Connection.init(subscription_index: nil)
    recipient = String.duplicate("9", 64)

    wrapped_welcome =
      valid_event(%{
        "kind" => 1059,
        "tags" => [["p", recipient], ["e", String.duplicate("a", 64)]],
        "content" => "encrypted-welcome-payload"
      })

    assert {:push, {:text, ok_frame}, ^state} =
             Connection.handle_in(
               {Jason.encode!(["EVENT", wrapped_welcome]), [opcode: :text]},
               state
             )

    assert Jason.decode!(ok_frame) == ["OK", wrapped_welcome["id"], true, "ok: event stored"]

    req_payload = Jason.encode!(["REQ", "sub-welcome", %{"kinds" => [1059], "#p" => [recipient]}])

    assert {:push, restricted_frames, ^state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded_restricted =
      Enum.map(restricted_frames, fn {:text, frame} -> Jason.decode!(frame) end)

    assert [
             "CLOSED",
             "sub-welcome",
             "restricted: giftwrap access requires recipient authentication"
           ] =
             Enum.find(decoded_restricted, fn frame -> List.first(frame) == "CLOSED" end)

    auth_event = valid_auth_event(state.auth_challenge, recipient)

    assert {:push, {:text, auth_frame}, authed_state} =
             Connection.handle_in({Jason.encode!(["AUTH", auth_event]), [opcode: :text]}, state)

    assert Jason.decode!(auth_frame) == ["OK", auth_event["id"], true, "ok: auth accepted"]

    assert {:push, frames, _next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, authed_state)

    decoded = Enum.map(frames, fn {:text, frame} -> Jason.decode!(frame) end)

    assert ["EVENT", "sub-welcome", result_event] =
             Enum.find(decoded, fn frame -> List.first(frame) == "EVENT" end)

    assert result_event["id"] == wrapped_welcome["id"]
    assert List.last(decoded) == ["EOSE", "sub-welcome"]
  end

  test "kind 445 commit ACK implies durable visibility before wrapped welcome ACK" do
    previous_features = Application.get_env(:parrhesia, :features, [])

    Application.put_env(:parrhesia, :features, Keyword.put(previous_features, :nip_ee_mls, true))

    on_exit(fn ->
      Application.put_env(:parrhesia, :features, previous_features)
    end)

    {:ok, state} = Connection.init(subscription_index: nil)

    commit_event =
      valid_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("b", 64)]],
        "content" => "commit-envelope"
      })

    assert {:push, {:text, commit_ok_frame}, ^state} =
             Connection.handle_in(
               {Jason.encode!(["EVENT", commit_event]), [opcode: :text]},
               state
             )

    assert Jason.decode!(commit_ok_frame) == ["OK", commit_event["id"], true, "ok: event stored"]

    assert {:ok, persisted_commit} = Storage.events().get_event(%{}, commit_event["id"])
    assert persisted_commit["id"] == commit_event["id"]

    wrapped_welcome =
      valid_event(%{
        "kind" => 1059,
        "tags" => [["p", String.duplicate("c", 64)], ["e", String.duplicate("d", 64)]],
        "content" => "encrypted-welcome-payload"
      })

    assert {:push, {:text, welcome_ok_frame}, ^state} =
             Connection.handle_in(
               {Jason.encode!(["EVENT", wrapped_welcome]), [opcode: :text]},
               state
             )

    assert Jason.decode!(welcome_ok_frame) == [
             "OK",
             wrapped_welcome["id"],
             true,
             "ok: event stored"
           ]

    assert {:ok, persisted_welcome} = Storage.events().get_event(%{}, wrapped_welcome["id"])
    assert persisted_welcome["id"] == wrapped_welcome["id"]
  end

  defp valid_event(overrides \\ %{}) do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => now,
      "kind" => 1,
      "tags" => [],
      "content" => "e2e",
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end

  defp valid_auth_event(challenge, pubkey) do
    event = %{
      "pubkey" => pubkey,
      "created_at" => System.system_time(:second),
      "kind" => 22_242,
      "tags" => [["challenge", challenge]],
      "content" => "",
      "sig" => String.duplicate("8", 128)
    }

    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
