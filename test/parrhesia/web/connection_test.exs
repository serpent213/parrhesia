defmodule Parrhesia.Web.ConnectionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Web.Connection

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "REQ registers subscription, streams initial events and replies with EOSE" do
    state = connection_state()

    req_payload = JSON.encode!(["REQ", "sub-123", %{"kinds" => [1]}])

    assert {:push, responses, next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    assert Map.has_key?(next_state.subscriptions, "sub-123")
    assert next_state.subscriptions["sub-123"].filters == [%{"kinds" => [1]}]
    assert next_state.subscriptions["sub-123"].eose_sent?

    assert List.last(Enum.map(responses, fn {:text, frame} -> JSON.decode!(frame) end)) == [
             "EOSE",
             "sub-123"
           ]
  end

  test "COUNT returns exact count payload" do
    state = connection_state()

    payload = JSON.encode!(["COUNT", "sub-count", %{"kinds" => [1]}])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert ["COUNT", "sub-count", payload] = JSON.decode!(response)
    assert payload["count"] >= 0
    assert payload["approximate"] == false
  end

  test "AUTH accepts valid challenge event" do
    state = connection_state()

    auth_event = valid_auth_event(state.auth_challenge)
    payload = JSON.encode!(["AUTH", auth_event])

    assert {:push, {:text, response}, next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == ["OK", auth_event["id"], true, "ok: auth accepted"]
    assert MapSet.member?(next_state.authenticated_pubkeys, auth_event["pubkey"])
    refute next_state.auth_challenge == state.auth_challenge
  end

  test "AUTH rejects mismatched challenge and returns AUTH frame" do
    state = connection_state()

    auth_event = valid_auth_event("wrong-challenge")
    payload = JSON.encode!(["AUTH", auth_event])

    assert {:push, frames, _next_state} = Connection.handle_in({payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert Enum.any?(decoded, fn frame -> frame == ["AUTH", state.auth_challenge] end)

    assert Enum.any?(decoded, fn frame ->
             match?(["OK", _, false, _], frame)
           end)
  end

  test "AUTH rejects relay tag mismatch" do
    state = connection_state(relay_url: "ws://localhost:4413/relay")

    auth_event = valid_auth_event(state.auth_challenge, relay_url: "ws://attacker.example/relay")
    payload = JSON.encode!(["AUTH", auth_event])

    assert {:push, frames, _next_state} = Connection.handle_in({payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert ["OK", _, false, "invalid: AUTH relay tag mismatch"] =
             Enum.find(decoded, fn frame -> List.first(frame) == "OK" end)
  end

  test "AUTH rejects stale events" do
    state = connection_state(auth_max_age_seconds: 600)

    stale_auth_event =
      valid_auth_event(state.auth_challenge,
        created_at: System.system_time(:second) - 601
      )

    payload = JSON.encode!(["AUTH", stale_auth_event])

    assert {:push, frames, _next_state} = Connection.handle_in({payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert ["OK", _, false, "invalid: AUTH event is too old"] =
             Enum.find(decoded, fn frame -> List.first(frame) == "OK" end)
  end

  test "protected event is rejected unless authenticated" do
    state = connection_state()

    event =
      valid_event()
      |> Map.put("tags", [["-"]])
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, frames, _next_state} = Connection.handle_in({payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert ["OK", _, false, "auth-required: protected events require authenticated pubkey"] =
             Enum.find(decoded, fn frame -> List.first(frame) == "OK" end)

    assert Enum.any?(decoded, fn frame -> frame == ["AUTH", state.auth_challenge] end)
  end

  test "kind 445 REQ without #h is rejected" do
    state = connection_state()

    req_payload = JSON.encode!(["REQ", "sub-445", %{"kinds" => [445]}])

    assert {:push, frames, _next_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)

    assert ["CLOSED", "sub-445", "restricted: kind 445 queries must include a #h tag"] =
             Enum.find(decoded, fn frame -> List.first(frame) == "CLOSED" end)
  end

  test "valid EVENT stores event and returns accepted OK" do
    state = connection_state()

    event = valid_event()
    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == ["OK", event["id"], true, "ok: event stored"]
  end

  test "ephemeral events are accepted without persistence" do
    previous_policies = Application.get_env(:parrhesia, :policies, [])

    Application.put_env(
      :parrhesia,
      :policies,
      Keyword.put(previous_policies, :accept_ephemeral_events, true)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :policies, previous_policies)
    end)

    state = connection_state()

    event = valid_event() |> Map.put("kind", 20_001) |> recalculate_event_id()
    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == ["OK", event["id"], true, "ok: ephemeral event accepted"]
    assert {:ok, nil} = Parrhesia.Storage.events().get_event(%{}, event["id"])
  end

  test "EVENT ingest enforces per-connection rate limits" do
    state = connection_state(max_event_ingest_per_window: 1, event_ingest_window_seconds: 60)

    first_event = valid_event(%{"content" => "first"})
    second_event = valid_event(%{"content" => "second"})

    assert {:push, {:text, first_response}, next_state} =
             Connection.handle_in({JSON.encode!(["EVENT", first_event]), [opcode: :text]}, state)

    assert JSON.decode!(first_response) == ["OK", first_event["id"], true, "ok: event stored"]

    assert {:push, {:text, second_response}, ^next_state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", second_event]), [opcode: :text]},
               next_state
             )

    assert JSON.decode!(second_response) == [
             "OK",
             second_event["id"],
             false,
             "rate-limited: too many EVENT messages"
           ]
  end

  test "EVENT ingest enforces max event bytes" do
    state = connection_state(max_event_bytes: 128)

    large_event =
      valid_event(%{"content" => String.duplicate("x", 256)})
      |> recalculate_event_id()

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({JSON.encode!(["EVENT", large_event]), [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             large_event["id"],
             false,
             "invalid: event exceeds max event size"
           ]
  end

  test "text frame size is rejected before JSON decoding" do
    state = connection_state(max_frame_bytes: 16)

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({String.duplicate("x", 17), [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "NOTICE",
             "invalid: websocket frame exceeds max frame size"
           ]
  end

  test "invalid EVENT replies with OK false invalid prefix" do
    state = connection_state()

    event = valid_event() |> Map.put("sig", "nope")
    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             event["id"],
             false,
             "invalid: sig must be 64-byte lowercase hex"
           ]
  end

  test "malformed wrapped welcome EVENT is rejected" do
    state = connection_state()

    event =
      valid_event()
      |> Map.put("kind", 1059)
      |> Map.put("tags", [["e", String.duplicate("a", 64)]])
      |> Map.put("content", "ciphertext")
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             event["id"],
             false,
             "invalid: kind 1059 must include at least one recipient p tag"
           ]
  end

  test "malformed kind 445 envelope EVENT is rejected" do
    state = connection_state()

    event =
      valid_event()
      |> Map.put("kind", 445)
      |> Map.put("tags", [["h", "not-hex"]])
      |> Map.put("content", "not-base64")
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             event["id"],
             false,
             "invalid: kind 445 content must be non-empty base64"
           ]
  end

  test "unsupported media metadata version EVENT is rejected by policy" do
    state = connection_state()

    event =
      valid_event()
      |> Map.put("kind", 1)
      |> Map.put("tags", [
        [
          "imeta",
          "url",
          "https://media.example/blob",
          "m",
          "image/jpeg",
          "x",
          String.duplicate("a", 64),
          "v",
          "mip04-v1"
        ]
      ])
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             event["id"],
             false,
             "blocked: media metadata version is not supported"
           ]
  end

  test "push trigger EVENT outside replay window is rejected" do
    previous_features = Application.get_env(:parrhesia, :features, [])
    previous_policies = Application.get_env(:parrhesia, :policies, [])

    server_pubkey = String.duplicate("e", 64)

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
      |> Keyword.put(:marmot_push_max_trigger_age_seconds, 5)
      |> Keyword.put(:marmot_push_require_expiration, true)
      |> Keyword.put(:marmot_push_max_expiration_window_seconds, 30)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :features, previous_features)
      Application.put_env(:parrhesia, :policies, previous_policies)
    end)

    state = connection_state()
    now = System.system_time(:second)

    event =
      valid_event()
      |> Map.put("kind", 1059)
      |> Map.put("created_at", now - 20)
      |> Map.put("tags", [["p", server_pubkey], ["expiration", Integer.to_string(now - 5)]])
      |> Map.put("content", "encrypted")
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(response) == [
             "OK",
             event["id"],
             false,
             "restricted: push notification trigger is outside replay window"
           ]
  end

  test "duplicate push trigger EVENT is rejected" do
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

    state = connection_state()
    now = System.system_time(:second)

    event =
      valid_event()
      |> Map.put("kind", 1059)
      |> Map.put("created_at", now)
      |> Map.put("tags", [["p", server_pubkey], ["expiration", Integer.to_string(now + 60)]])
      |> Map.put("content", "encrypted")
      |> then(&Map.put(&1, "id", EventValidator.compute_id(&1)))

    payload = JSON.encode!(["EVENT", event])

    assert {:push, {:text, first_response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(first_response) == ["OK", event["id"], true, "ok: event stored"]

    assert {:push, {:text, second_response}, _next_state} =
             Connection.handle_in({payload, [opcode: :text]}, state)

    assert JSON.decode!(second_response) == [
             "OK",
             event["id"],
             false,
             "duplicate: event already stored"
           ]
  end

  test "NEG sessions open and close" do
    state = connection_state()

    open_payload = JSON.encode!(["NEG-OPEN", "neg-1", %{"cursor" => 0}])

    assert {:push, {:text, open_response}, _next_state} =
             Connection.handle_in({open_payload, [opcode: :text]}, state)

    assert ["NEG-MSG", "neg-1", %{"status" => "open", "cursor" => 0}] =
             JSON.decode!(open_response)

    close_payload = JSON.encode!(["NEG-CLOSE", "neg-1"])

    assert {:push, {:text, close_response}, _next_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, state)

    assert JSON.decode!(close_response) == ["NEG-MSG", "neg-1", %{"status" => "closed"}]
  end

  test "CLOSE removes subscription and replies with CLOSED" do
    state = subscribed_connection_state([])

    close_payload = JSON.encode!(["CLOSE", "sub-1"])

    assert {:push, {:text, response}, next_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, state)

    refute Map.has_key?(next_state.subscriptions, "sub-1")
    assert JSON.decode!(response) == ["CLOSED", "sub-1", "error: subscription closed"]
  end

  test "fanout_event enqueues and drains matching events" do
    state = subscribed_connection_state([])
    event = live_event("event-1", 1)

    assert {:ok, queued_state} = Connection.handle_info({:fanout_event, "sub-1", event}, state)
    assert queued_state.outbound_queue_size == 1

    assert_receive :drain_outbound_queue

    assert {:push, [{:text, payload}], drained_state} =
             Connection.handle_info(:drain_outbound_queue, queued_state)

    assert drained_state.outbound_queue_size == 0
    assert JSON.decode!(payload) == ["EVENT", "sub-1", event]
  end

  test "high-volume kind 445 fanout drains in order across batches" do
    group_id = String.duplicate("c", 64)

    state =
      subscribed_group_connection_state(group_id,
        max_outbound_queue: 256,
        outbound_drain_batch_size: 16
      )

    events =
      Enum.map(1..70, fn idx ->
        live_group_event("group-event-#{idx}", group_id)
      end)

    fanout_events = Enum.map(events, &{"sub-group", &1})

    assert {:ok, queued_state} = Connection.handle_info({:fanout_events, fanout_events}, state)
    assert queued_state.outbound_queue_size == 70

    frames = drain_all_event_frames(queued_state)

    delivered_ids =
      frames
      |> Enum.map(fn {:text, payload} -> JSON.decode!(payload) end)
      |> Enum.map(fn ["EVENT", "sub-group", event] -> event["id"] end)

    assert delivered_ids == Enum.map(events, & &1["id"])
  end

  test "outbound queue overflow closes connection when strategy is close" do
    state =
      subscribed_connection_state(
        max_outbound_queue: 1,
        outbound_overflow_strategy: :close,
        outbound_drain_batch_size: 1
      )

    assert {:ok, queued_state} =
             Connection.handle_info({:fanout_event, "sub-1", live_event("event-1", 1)}, state)

    assert_receive :drain_outbound_queue

    assert {:stop, :normal, {1008, message}, [{:text, notice_payload}], _overflow_state} =
             Connection.handle_info(
               {:fanout_event, "sub-1", live_event("event-2", 1)},
               queued_state
             )

    assert message == "rate-limited: outbound queue overflow"
    assert JSON.decode!(notice_payload) == ["NOTICE", message]
  end

  defp subscribed_connection_state(opts) do
    state = connection_state(opts)
    req_payload = JSON.encode!(["REQ", "sub-1", %{"kinds" => [1]}])

    assert {:push, _, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    subscribed_state
  end

  defp subscribed_group_connection_state(group_id, opts) do
    state = connection_state(opts)
    req_payload = JSON.encode!(["REQ", "sub-group", %{"kinds" => [445], "#h" => [group_id]}])

    assert {:push, _, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    subscribed_state
  end

  defp connection_state(opts \\ []) do
    {:ok, state} = Connection.init(Keyword.put_new(opts, :subscription_index, nil))
    state
  end

  defp live_event(id, kind) do
    %{
      "id" => id,
      "pubkey" => String.duplicate("a", 64),
      "created_at" => System.system_time(:second),
      "kind" => kind,
      "tags" => [],
      "content" => "live",
      "sig" => String.duplicate("b", 128)
    }
  end

  defp live_group_event(id, group_id) do
    %{
      "id" => id,
      "pubkey" => String.duplicate("a", 64),
      "created_at" => System.system_time(:second),
      "kind" => 445,
      "tags" => [["h", group_id]],
      "content" => Base.encode64("mls-group-message"),
      "sig" => String.duplicate("b", 128)
    }
  end

  defp valid_auth_event(challenge, opts \\ []) do
    now = Keyword.get(opts, :created_at, System.system_time(:second))
    relay_url = Keyword.get(opts, :relay_url, Parrhesia.Config.get([:relay_url]))

    base = %{
      "pubkey" => String.duplicate("9", 64),
      "created_at" => now,
      "kind" => 22_242,
      "tags" => [["challenge", challenge], ["relay", relay_url]],
      "content" => "",
      "sig" => String.duplicate("8", 128)
    }

    Map.put(base, "id", EventValidator.compute_id(base))
  end

  defp drain_all_event_frames(state), do: drain_all_event_frames(state, [])

  defp drain_all_event_frames(%{outbound_queue_size: 0}, acc) do
    flush_drain_messages()
    Enum.reverse(acc)
  end

  defp drain_all_event_frames(state, acc) do
    case Connection.handle_info(:drain_outbound_queue, state) do
      {:push, frames, next_state} ->
        drain_all_event_frames(next_state, Enum.reverse(frames) ++ acc)

      {:ok, next_state} ->
        drain_all_event_frames(next_state, acc)
    end
  end

  defp flush_drain_messages do
    receive do
      :drain_outbound_queue -> flush_drain_messages()
    after
      0 -> :ok
    end
  end

  defp valid_event(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "hello",
      "sig" => String.duplicate("3", 128)
    }

    base_event
    |> Map.merge(overrides)
    |> recalculate_event_id()
  end

  defp recalculate_event_id(event) do
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
