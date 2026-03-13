defmodule Parrhesia.Policy.EventPolicyTest do
  use ExUnit.Case, async: false

  alias Parrhesia.Policy.EventPolicy

  alias Parrhesia.TestSupport.PermissiveModeration

  setup do
    previous_policies = Application.get_env(:parrhesia, :policies, [])
    previous_features = Application.get_env(:parrhesia, :features, [])
    previous_storage = Application.get_env(:parrhesia, :storage, [])

    Application.put_env(
      :parrhesia,
      :storage,
      Keyword.put(previous_storage, :moderation, PermissiveModeration)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :policies, previous_policies)
      Application.put_env(:parrhesia, :features, previous_features)
      Application.put_env(:parrhesia, :storage, previous_storage)
    end)

    :ok
  end

  test "requires auth for reads when configured" do
    Application.put_env(:parrhesia, :policies, auth_required_for_reads: true)

    assert {:error, :auth_required} =
             EventPolicy.authorize_read([%{"kinds" => [1]}], MapSet.new())

    assert :ok =
             EventPolicy.authorize_read(
               [%{"kinds" => [1]}],
               MapSet.new([String.duplicate("a", 64)])
             )
  end

  test "restricts giftwrap reads without recipient auth" do
    filter = %{"kinds" => [1059], "#p" => [String.duplicate("b", 64)]}

    assert {:error, :restricted_giftwrap} = EventPolicy.authorize_read([filter], MapSet.new())

    assert :ok =
             EventPolicy.authorize_read([filter], MapSet.new([String.duplicate("b", 64)]))
  end

  test "rejects protected events without auth" do
    event = %{"tags" => [["-"]], "pubkey" => String.duplicate("c", 64), "id" => ""}

    assert {:error, :protected_event_requires_auth} =
             EventPolicy.authorize_write(event, MapSet.new())

    assert :ok =
             EventPolicy.authorize_write(event, MapSet.new([String.duplicate("c", 64)]))
  end

  test "requires #h when querying kind 445" do
    filter = %{"kinds" => [445]}

    assert {:error, :marmot_group_h_tag_required} =
             EventPolicy.authorize_read([filter], MapSet.new())

    assert :ok =
             EventPolicy.authorize_read(
               [%{"kinds" => [445], "#h" => [String.duplicate("a", 64)]}],
               MapSet.new()
             )
  end

  test "enforces max #h values and query window for kind 445 filters" do
    Application.put_env(
      :parrhesia,
      :policies,
      marmot_group_max_h_values_per_filter: 1,
      marmot_group_max_query_window_seconds: 10,
      marmot_require_h_for_group_queries: true
    )

    too_many_groups = %{
      "kinds" => [445],
      "#h" => [String.duplicate("a", 64), String.duplicate("b", 64)]
    }

    wide_window = %{
      "kinds" => [445],
      "#h" => [String.duplicate("c", 64)],
      "since" => 1,
      "until" => 100
    }

    assert {:error, :marmot_group_h_values_exceeded} =
             EventPolicy.authorize_read([too_many_groups], MapSet.new())

    assert {:error, :marmot_group_filter_window_too_wide} =
             EventPolicy.authorize_read([wide_window], MapSet.new())
  end

  test "accepts MIP-04 media metadata events as regular Nostr events" do
    media_event = %{
      "kind" => 1,
      "tags" => [
        [
          "imeta",
          "url",
          "https://media.example/blob",
          "m",
          "image/jpeg",
          "x",
          String.duplicate("a", 64),
          "v",
          "mip04-v2"
        ]
      ],
      "pubkey" => String.duplicate("d", 64),
      "id" => ""
    }

    assert :ok =
             EventPolicy.authorize_write(media_event, MapSet.new([String.duplicate("d", 64)]))
  end

  test "enforces media metadata tag limits" do
    Application.put_env(
      :parrhesia,
      :policies,
      marmot_media_max_imeta_tags_per_event: 1,
      marmot_media_max_field_value_bytes: 1024,
      marmot_media_max_url_bytes: 2048,
      marmot_media_allowed_mime_prefixes: [],
      marmot_media_reject_mip04_v1: true
    )

    event = %{
      "kind" => 1,
      "tags" => [
        [
          "imeta",
          "url",
          "https://media.example/1",
          "m",
          "image/jpeg",
          "x",
          String.duplicate("a", 64)
        ],
        [
          "imeta",
          "url",
          "https://media.example/2",
          "m",
          "image/jpeg",
          "x",
          String.duplicate("b", 64)
        ]
      ],
      "pubkey" => String.duplicate("d", 64),
      "id" => ""
    }

    assert {:error, :media_metadata_tags_exceeded} =
             EventPolicy.authorize_write(event, MapSet.new([String.duplicate("d", 64)]))
  end

  test "rejects disallowed media mime types and unsupported versions" do
    Application.put_env(
      :parrhesia,
      :policies,
      marmot_media_max_imeta_tags_per_event: 8,
      marmot_media_max_field_value_bytes: 1024,
      marmot_media_max_url_bytes: 2048,
      marmot_media_allowed_mime_prefixes: ["image/"],
      marmot_media_reject_mip04_v1: true
    )

    invalid_mime_event = %{
      "kind" => 1,
      "tags" => [
        [
          "imeta",
          "url",
          "https://media.example/1",
          "m",
          "video/mp4",
          "x",
          String.duplicate("a", 64)
        ]
      ],
      "pubkey" => String.duplicate("d", 64),
      "id" => ""
    }

    unsupported_version_event = %{
      "kind" => 1,
      "tags" => [
        [
          "imeta",
          "url",
          "https://media.example/1",
          "m",
          "image/jpeg",
          "x",
          String.duplicate("a", 64),
          "v",
          "mip04-v1"
        ]
      ],
      "pubkey" => String.duplicate("d", 64),
      "id" => ""
    }

    assert {:error, :media_metadata_mime_not_allowed} =
             EventPolicy.authorize_write(
               invalid_mime_event,
               MapSet.new([String.duplicate("d", 64)])
             )

    assert {:error, :media_metadata_unsupported_version} =
             EventPolicy.authorize_write(
               unsupported_version_event,
               MapSet.new([String.duplicate("d", 64)])
             )
  end

  test "accepts push coordination events when push feature is enabled" do
    server_pubkey = String.duplicate("f", 64)

    Application.put_env(
      :parrhesia,
      :features,
      nip_ee_mls: false,
      marmot_push_notifications: true
    )

    Application.put_env(
      :parrhesia,
      :policies,
      marmot_push_server_pubkeys: [server_pubkey],
      marmot_push_max_relay_tags: 16,
      marmot_push_max_payload_bytes: 65_536,
      marmot_push_max_trigger_age_seconds: 300,
      marmot_push_require_expiration: true,
      marmot_push_max_expiration_window_seconds: 120,
      marmot_push_max_server_recipients: 1
    )

    relay_list_event = %{
      "kind" => 10_050,
      "tags" => [["relay", "wss://notify.example"], ["relay", "wss://notify2.example"]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => System.system_time(:second),
      "content" => ""
    }

    now = System.system_time(:second)

    trigger_event = %{
      "kind" => 1059,
      "tags" => [["p", server_pubkey], ["expiration", Integer.to_string(now + 60)]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now,
      "content" => "encrypted-push"
    }

    assert :ok =
             EventPolicy.authorize_write(
               relay_list_event,
               MapSet.new([String.duplicate("d", 64)])
             )

    assert :ok =
             EventPolicy.authorize_write(trigger_event, MapSet.new([String.duplicate("d", 64)]))
  end

  test "enforces push policy limits for relay-list and trigger payloads" do
    server_pubkey = String.duplicate("e", 64)

    Application.put_env(
      :parrhesia,
      :features,
      nip_ee_mls: false,
      marmot_push_notifications: true
    )

    Application.put_env(
      :parrhesia,
      :policies,
      marmot_push_server_pubkeys: [server_pubkey],
      marmot_push_max_relay_tags: 1,
      marmot_push_max_payload_bytes: 8,
      marmot_push_max_trigger_age_seconds: 300,
      marmot_push_require_expiration: true,
      marmot_push_max_expiration_window_seconds: 120,
      marmot_push_max_server_recipients: 1
    )

    relay_list_event = %{
      "kind" => 10_050,
      "tags" => [["relay", "wss://notify.example"], ["relay", "wss://notify2.example"]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => System.system_time(:second),
      "content" => ""
    }

    now = System.system_time(:second)

    oversized_trigger = %{
      "kind" => 1059,
      "tags" => [["p", server_pubkey], ["expiration", Integer.to_string(now + 60)]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now,
      "content" => "encrypted-push-too-large"
    }

    assert {:error, :push_notification_relay_tags_exceeded} =
             EventPolicy.authorize_write(
               relay_list_event,
               MapSet.new([String.duplicate("d", 64)])
             )

    assert {:error, :push_notification_payload_too_large} =
             EventPolicy.authorize_write(
               oversized_trigger,
               MapSet.new([String.duplicate("d", 64)])
             )
  end

  test "enforces push replay and expiration protection" do
    server_pubkey = String.duplicate("c", 64)
    now = System.system_time(:second)

    Application.put_env(
      :parrhesia,
      :features,
      nip_ee_mls: false,
      marmot_push_notifications: true
    )

    Application.put_env(
      :parrhesia,
      :policies,
      marmot_push_server_pubkeys: [server_pubkey],
      marmot_push_max_relay_tags: 16,
      marmot_push_max_payload_bytes: 65_536,
      marmot_push_max_trigger_age_seconds: 5,
      marmot_push_require_expiration: true,
      marmot_push_max_expiration_window_seconds: 30,
      marmot_push_max_server_recipients: 1
    )

    stale_trigger = %{
      "kind" => 1059,
      "tags" => [["p", server_pubkey], ["expiration", Integer.to_string(now - 50)]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now - 20,
      "content" => "encrypted"
    }

    missing_expiration = %{
      "kind" => 1059,
      "tags" => [["p", server_pubkey]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now,
      "content" => "encrypted"
    }

    far_expiration = %{
      "kind" => 1059,
      "tags" => [["p", server_pubkey], ["expiration", Integer.to_string(now + 120)]],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now,
      "content" => "encrypted"
    }

    multi_server_target = %{
      "kind" => 1059,
      "tags" => [
        ["p", server_pubkey],
        ["p", String.duplicate("b", 64)],
        ["expiration", Integer.to_string(now + 20)]
      ],
      "pubkey" => String.duplicate("d", 64),
      "id" => "",
      "created_at" => now,
      "content" => "encrypted"
    }

    Application.put_env(
      :parrhesia,
      :policies,
      marmot_push_server_pubkeys: [server_pubkey, String.duplicate("b", 64)],
      marmot_push_max_relay_tags: 16,
      marmot_push_max_payload_bytes: 65_536,
      marmot_push_max_trigger_age_seconds: 5,
      marmot_push_require_expiration: true,
      marmot_push_max_expiration_window_seconds: 30,
      marmot_push_max_server_recipients: 1
    )

    assert {:error, :push_notification_replay_window_exceeded} =
             EventPolicy.authorize_write(stale_trigger, MapSet.new([String.duplicate("d", 64)]))

    assert {:error, :push_notification_missing_expiration} =
             EventPolicy.authorize_write(
               missing_expiration,
               MapSet.new([String.duplicate("d", 64)])
             )

    assert {:error, :push_notification_expiration_too_far} =
             EventPolicy.authorize_write(far_expiration, MapSet.new([String.duplicate("d", 64)]))

    assert {:error, :push_notification_server_recipients_exceeded} =
             EventPolicy.authorize_write(
               multi_server_target,
               MapSet.new([String.duplicate("d", 64)])
             )
  end

  test "rejects mls kinds when feature is disabled" do
    Application.put_env(:parrhesia, :features, nip_ee_mls: false)

    event = %{"kind" => 443, "tags" => [], "pubkey" => String.duplicate("d", 64), "id" => ""}

    assert {:error, :mls_disabled} =
             EventPolicy.authorize_write(event, MapSet.new([String.duplicate("d", 64)]))
  end

  test "enforces min pow difficulty" do
    Application.put_env(:parrhesia, :policies, min_pow_difficulty: 8)

    weak_pow_event = %{
      "kind" => 1,
      "tags" => [],
      "pubkey" => String.duplicate("e", 64),
      "id" => "ff1234"
    }

    assert {:error, :pow_below_minimum} =
             EventPolicy.authorize_write(weak_pow_event, MapSet.new([String.duplicate("e", 64)]))
  end
end
