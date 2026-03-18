defmodule Parrhesia.Web.ConnectionNIP43Test do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Groups.Flow
  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Storage
  alias Parrhesia.Web.Connection

  test "REQ for kind 28935 returns a relay-signed invite response" do
    state = connection_state()

    assert {:push, frames, next_state} =
             Connection.handle_in(
               {JSON.encode!(["REQ", "sub-invite", %{"kinds" => [28_935]}]), [opcode: :text]},
               state
             )

    assert next_state.subscriptions["sub-invite"].eose_sent?

    decoded = Enum.map(frames, fn {:text, frame} -> JSON.decode!(frame) end)
    assert ["EOSE", "sub-invite"] = List.last(decoded)

    assert ["EVENT", "sub-invite", invite_event] =
             Enum.find(decoded, fn frame -> List.first(frame) == "EVENT" end)

    assert invite_event["kind"] == 28_935
    assert :ok = Protocol.validate_event(invite_event)
    assert is_binary(claim_from_event(invite_event))
  end

  test "join request accepts valid claims, stores membership, and publishes membership events" do
    invite_event = request_invite_event()
    join_pubkey = String.duplicate("9", 64)

    join_request =
      valid_event(%{
        "pubkey" => join_pubkey,
        "kind" => 28_934,
        "tags" => [["-"], ["claim", claim_from_event(invite_event)]],
        "content" => ""
      })

    assert {:push, {:text, response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", join_request]), [opcode: :text]},
               connection_state()
             )

    assert JSON.decode!(response) == [
             "OK",
             join_request["id"],
             true,
             "info: welcome to ws://localhost:4413/relay!"
           ]

    assert {:ok, membership} = Flow.get_membership(join_pubkey)
    assert membership.role == "member"

    assert {:ok, add_events} =
             Storage.events().query(%{}, [%{"kinds" => [8_000], "#p" => [join_pubkey]}], [])

    assert length(add_events) == 1

    assert {:ok, membership_list_events} =
             Storage.events().query(%{}, [%{"kinds" => [13_534]}], [])

    assert Enum.any?(membership_list_events, fn event ->
             ["member", join_pubkey] in event["tags"]
           end)
  end

  test "join request rejects invalid claims" do
    join_request =
      valid_event(%{
        "kind" => 28_934,
        "tags" => [["-"], ["claim", "invalid-claim"]],
        "content" => ""
      })

    assert {:push, {:text, response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", join_request]), [opcode: :text]},
               connection_state()
             )

    assert JSON.decode!(response) == [
             "OK",
             join_request["id"],
             false,
             "restricted: that is an invalid invite code."
           ]
  end

  test "duplicate join and leave requests return duplicate messages" do
    invite_event = request_invite_event()
    member_pubkey = String.duplicate("8", 64)

    first_join =
      valid_event(%{
        "pubkey" => member_pubkey,
        "kind" => 28_934,
        "tags" => [["-"], ["claim", claim_from_event(invite_event)]],
        "content" => ""
      })

    second_join =
      valid_event(%{
        "pubkey" => member_pubkey,
        "created_at" => System.system_time(:second) + 1,
        "kind" => 28_934,
        "tags" => [["-"], ["claim", claim_from_event(invite_event)]],
        "content" => ""
      })

    assert {:push, {:text, _response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", first_join]), [opcode: :text]},
               connection_state()
             )

    assert {:push, {:text, duplicate_join_response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", second_join]), [opcode: :text]},
               connection_state()
             )

    assert JSON.decode!(duplicate_join_response) == [
             "OK",
             second_join["id"],
             true,
             "duplicate: you are already a member of this relay."
           ]

    leave_request =
      valid_event(%{
        "pubkey" => member_pubkey,
        "kind" => 28_936,
        "tags" => [["-"]],
        "content" => ""
      })

    duplicate_leave =
      valid_event(%{
        "pubkey" => member_pubkey,
        "created_at" => System.system_time(:second) + 2,
        "kind" => 28_936,
        "tags" => [["-"]],
        "content" => ""
      })

    assert {:push, {:text, leave_response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", leave_request]), [opcode: :text]},
               connection_state()
             )

    assert JSON.decode!(leave_response) == [
             "OK",
             leave_request["id"],
             true,
             "info: membership revoked."
           ]

    assert {:push, {:text, duplicate_leave_response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", duplicate_leave]), [opcode: :text]},
               connection_state()
             )

    assert JSON.decode!(duplicate_leave_response) == [
             "OK",
             duplicate_leave["id"],
             true,
             "duplicate: you are not a member of this relay."
           ]
  end

  test "leave request publishes a remove event and prunes the membership list" do
    invite_event = request_invite_event()
    member_pubkey = String.duplicate("7", 64)

    join_request =
      valid_event(%{
        "pubkey" => member_pubkey,
        "kind" => 28_934,
        "tags" => [["-"], ["claim", claim_from_event(invite_event)]],
        "content" => ""
      })

    leave_request =
      valid_event(%{
        "pubkey" => member_pubkey,
        "created_at" => System.system_time(:second) + 1,
        "kind" => 28_936,
        "tags" => [["-"]],
        "content" => ""
      })

    assert {:push, {:text, _response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", join_request]), [opcode: :text]},
               connection_state()
             )

    assert {:push, {:text, _response}, _state} =
             Connection.handle_in(
               {JSON.encode!(["EVENT", leave_request]), [opcode: :text]},
               connection_state()
             )

    assert {:ok, nil} = Flow.get_membership(member_pubkey)

    assert {:ok, remove_events} =
             Storage.events().query(%{}, [%{"kinds" => [8_001], "#p" => [member_pubkey]}], [])

    assert length(remove_events) == 1

    assert {:ok, membership_list_events} =
             Storage.events().query(%{}, [%{"kinds" => [13_534]}], [])

    assert Enum.any?(membership_list_events, fn event ->
             ["member", member_pubkey] not in event["tags"]
           end)
  end

  defp request_invite_event do
    state = connection_state()

    assert {:push, frames, _next_state} =
             Connection.handle_in(
               {JSON.encode!(["REQ", "sub-invite", %{"kinds" => [28_935]}]), [opcode: :text]},
               state
             )

    frames
    |> Enum.map(fn {:text, frame} -> JSON.decode!(frame) end)
    |> Enum.find_value(fn
      ["EVENT", "sub-invite", invite_event] -> invite_event
      _frame -> nil
    end)
  end

  defp claim_from_event(event) do
    event
    |> Map.get("tags", [])
    |> Enum.find_value(fn
      ["claim", claim | _rest] -> claim
      _tag -> nil
    end)
  end

  defp connection_state(opts \\ []) do
    {:ok, state} = Connection.init(Keyword.put_new(opts, :subscription_index, nil))
    state
  end

  defp valid_event(overrides) do
    %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "",
      "sig" => String.duplicate("3", 128)
    }
    |> Map.merge(overrides)
    |> then(fn event -> Map.put(event, "id", EventValidator.compute_id(event)) end)
  end
end
