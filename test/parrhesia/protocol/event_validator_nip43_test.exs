defmodule Parrhesia.Protocol.EventValidatorNIP43Test do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol.EventValidator

  test "accepts valid NIP-43 relay access events" do
    join_request =
      build_event(%{
        "kind" => 28_934,
        "tags" => [["-"], ["claim", "invite-code"]],
        "content" => ""
      })

    invite_response =
      build_event(%{
        "kind" => 28_935,
        "tags" => [["-"], ["claim", "invite-code"]],
        "content" => ""
      })

    leave_request =
      build_event(%{
        "kind" => 28_936,
        "tags" => [["-"]],
        "content" => ""
      })

    add_user =
      build_event(%{
        "kind" => 8_000,
        "tags" => [["-"], ["p", String.duplicate("a", 64)]],
        "content" => ""
      })

    remove_user =
      build_event(%{
        "kind" => 8_001,
        "tags" => [["-"], ["p", String.duplicate("b", 64)]],
        "content" => ""
      })

    membership_list =
      build_event(%{
        "kind" => 13_534,
        "tags" => [
          ["-"],
          ["member", String.duplicate("c", 64)],
          ["member", String.duplicate("d", 64)]
        ],
        "content" => ""
      })

    assert :ok = EventValidator.validate(join_request)
    assert :ok = EventValidator.validate(invite_response)
    assert :ok = EventValidator.validate(leave_request)
    assert :ok = EventValidator.validate(add_user)
    assert :ok = EventValidator.validate(remove_user)
    assert :ok = EventValidator.validate(membership_list)
  end

  test "rejects malformed NIP-43 relay access events" do
    stale_join =
      build_event(%{
        "kind" => 28_934,
        "created_at" => System.system_time(:second) - 301,
        "tags" => [["-"], ["claim", "invite-code"]],
        "content" => ""
      })

    missing_claim =
      build_event(%{
        "kind" => 28_935,
        "tags" => [["-"]],
        "content" => ""
      })

    invalid_leave =
      build_event(%{
        "kind" => 28_936,
        "tags" => [],
        "content" => ""
      })

    invalid_membership_delta =
      build_event(%{
        "kind" => 8_000,
        "tags" => [["-"], ["p", "not-a-pubkey"]],
        "content" => ""
      })

    invalid_membership_list =
      build_event(%{
        "kind" => 13_534,
        "tags" => [["-"], ["member", "not-a-pubkey"]],
        "content" => ""
      })

    assert {:error, :stale_nip43_join_request} = EventValidator.validate(stale_join)
    assert {:error, :missing_nip43_claim_tag} = EventValidator.validate(missing_claim)
    assert {:error, :missing_nip43_protected_tag} = EventValidator.validate(invalid_leave)

    assert {:error, :invalid_nip43_pubkey_tag} =
             EventValidator.validate(invalid_membership_delta)

    assert {:error, :invalid_nip43_member_tag} =
             EventValidator.validate(invalid_membership_list)
  end

  defp build_event(overrides) do
    event =
      %{
        "pubkey" => String.duplicate("1", 64),
        "created_at" => System.system_time(:second),
        "kind" => 1,
        "tags" => [],
        "content" => "",
        "sig" => String.duplicate("2", 128)
      }
      |> Map.merge(overrides)

    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
