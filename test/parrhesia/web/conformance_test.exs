defmodule Parrhesia.Web.ConformanceTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Storage
  alias Parrhesia.Web.Connection

  test "REQ -> EOSE emitted once and CLOSE emits CLOSED" do
    {:ok, state} = Connection.init(subscription_index: nil)

    req_payload = JSON.encode!(["REQ", "sub-e2e", %{"kinds" => [1]}])

    assert {:push, frames, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)
    assert ["EOSE", "sub-e2e"] = List.last(decoded)

    close_payload = JSON.encode!(["CLOSE", "sub-e2e"])

    assert {:push, {:text, closed_frame}, closed_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, subscribed_state)

    assert JSON.decode!(closed_frame) == ["CLOSED", "sub-e2e", "error: subscription closed"]
    refute Map.has_key?(closed_state.subscriptions, "sub-e2e")
  end

  test "EVENT accepted path returns canonical OK frame" do
    {:ok, state} = Connection.init(subscription_index: nil)

    event = valid_event()

    assert {:push, {:text, frame}, _next_state} =
             Connection.handle_in({JSON.encode!(["EVENT", event]), [opcode: :text]}, state)

    assert JSON.decode!(frame) == ["OK", event["id"], true, "ok: event stored"]
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

    assert {:push, {:text, ok_frame}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", wrapped_welcome]), [opcode: :text]},
               state
             )

    assert JSON.decode!(ok_frame) == ["OK", wrapped_welcome["id"], true, "ok: event stored"]

    req_payload = JSON.encode!(["REQ", "sub-welcome", %{"kinds" => [1059], "#p" => [recipient]}])

    assert {:push, restricted_frames, _next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded_restricted =
      Enum.map(restricted_frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert [
             "CLOSED",
             "sub-welcome",
             "restricted: giftwrap access requires recipient authentication"
           ] =
             Enum.find(decoded_restricted, fn frame -> List.first(frame) == "CLOSED" end)

    auth_event = valid_auth_event(state.auth_challenge, recipient)

    assert {:push, {:text, auth_frame}, authed_state} =
             Connection.handle_in({JSON.encode!(["AUTH", auth_event]), [opcode: :text]}, state)

    assert JSON.decode!(auth_frame) == ["OK", auth_event["id"], true, "ok: auth accepted"]

    assert {:push, frames, _next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, authed_state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert ["EVENT", "sub-welcome", result_event] =
             Enum.find(decoded, fn frame -> List.first(frame) == "EVENT" end)

    assert result_event["id"] == wrapped_welcome["id"]
    assert List.last(decoded) == ["EOSE", "sub-welcome"]
  end

  test "kind 445 commit ACK implies durable visibility before wrapped welcome ACK" do
    {:ok, state} = Connection.init(subscription_index: nil)

    commit_event =
      valid_event(%{
        "kind" => 445,
        "tags" => [["h", String.duplicate("b", 64)]],
        "content" => Base.encode64("commit-envelope")
      })

    assert {:push, {:text, commit_ok_frame}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", commit_event]), [opcode: :text]},
               state
             )

    assert JSON.decode!(commit_ok_frame) == ["OK", commit_event["id"], true, "ok: event stored"]

    assert {:ok, persisted_commit} = Storage.events().get_event(%{}, commit_event["id"])
    assert persisted_commit["id"] == commit_event["id"]

    wrapped_welcome =
      valid_event(%{
        "kind" => 1059,
        "tags" => [["p", String.duplicate("c", 64)], ["e", String.duplicate("d", 64)]],
        "content" => "encrypted-welcome-payload"
      })

    assert {:push, {:text, welcome_ok_frame}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", wrapped_welcome]), [opcode: :text]},
               state
             )

    assert JSON.decode!(welcome_ok_frame) == [
             "OK",
             wrapped_welcome["id"],
             true,
             "ok: event stored"
           ]

    assert {:ok, persisted_welcome} = Storage.events().get_event(%{}, wrapped_welcome["id"])
    assert persisted_welcome["id"] == wrapped_welcome["id"]
  end

  test "push coordination events are accepted and stored when feature is enabled" do
    previous_features = Application.get_env(:parrhesia, :features, [])
    previous_policies = Application.get_env(:parrhesia, :policies, [])

    server_pubkey = String.duplicate("f", 64)

    Application.put_env(
      :parrhesia,
      :features,
      Keyword.put(previous_features, :marmot_push_notifications, true)
    )

    Application.put_env(
      :parrhesia,
      :policies,
      previous_policies
      |> Keyword.put(:marmot_push_server_pubkeys, [server_pubkey])
      |> Keyword.put(:marmot_push_max_trigger_age_seconds, 300)
      |> Keyword.put(:marmot_push_require_expiration, true)
      |> Keyword.put(:marmot_push_max_expiration_window_seconds, 120)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :features, previous_features)
      Application.put_env(:parrhesia, :policies, previous_policies)
    end)

    {:ok, state} = Connection.init(subscription_index: nil)

    relay_list_event =
      valid_event(%{
        "kind" => 10_050,
        "tags" => [["relay", "wss://notify.example"], ["relay", "wss://notify2.example"]],
        "content" => ""
      })

    now = System.system_time(:second)

    push_trigger =
      valid_event(%{
        "kind" => 1059,
        "created_at" => now,
        "tags" => [["p", server_pubkey], ["expiration", Integer.to_string(now + 60)]],
        "content" => "encrypted-push"
      })

    assert {:push, {:text, relay_ok_frame}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", relay_list_event]), [opcode: :text]},
               state
             )

    assert JSON.decode!(relay_ok_frame) == [
             "OK",
             relay_list_event["id"],
             true,
             "ok: event stored"
           ]

    assert {:push, {:text, trigger_ok_frame}, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", push_trigger]), [opcode: :text]},
               state
             )

    assert JSON.decode!(trigger_ok_frame) == ["OK", push_trigger["id"], true, "ok: event stored"]

    assert {:ok, persisted_relay_list} = Storage.events().get_event(%{}, relay_list_event["id"])
    assert persisted_relay_list["id"] == relay_list_event["id"]

    assert {:ok, persisted_trigger} = Storage.events().get_event(%{}, push_trigger["id"])
    assert persisted_trigger["id"] == push_trigger["id"]
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
    relay_url = Parrhesia.Config.get([:relay_url])

    event = %{
      "pubkey" => pubkey,
      "created_at" => System.system_time(:second),
      "kind" => 22_242,
      "tags" => [["challenge", challenge], ["relay", relay_url]],
      "content" => "",
      "sig" => String.duplicate("8", 128)
    }

    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
