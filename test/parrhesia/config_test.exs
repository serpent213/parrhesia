defmodule Parrhesia.ConfigTest do
  use ExUnit.Case, async: true

  test "returns configured relay limits/policies/features" do
    assert Parrhesia.Config.get([:limits, :max_frame_bytes]) == 1_048_576
    assert Parrhesia.Config.get([:limits, :max_event_bytes]) == 262_144
    assert Parrhesia.Config.get([:limits, :max_event_future_skew_seconds]) == 900
    assert Parrhesia.Config.get([:limits, :max_event_ingest_per_window]) == 120
    assert Parrhesia.Config.get([:limits, :event_ingest_window_seconds]) == 1
    assert Parrhesia.Config.get([:limits, :auth_max_age_seconds]) == 600
    assert Parrhesia.Config.get([:limits, :max_outbound_queue]) == 256
    assert Parrhesia.Config.get([:limits, :max_filter_limit]) == 500
    assert Parrhesia.Config.get([:relay_url]) == "ws://localhost:4000/relay"
    assert Parrhesia.Config.get([:policies, :auth_required_for_writes]) == false
    assert Parrhesia.Config.get([:policies, :marmot_media_max_imeta_tags_per_event]) == 8
    assert Parrhesia.Config.get([:policies, :marmot_media_reject_mip04_v1]) == true
    assert Parrhesia.Config.get([:policies, :marmot_push_max_trigger_age_seconds]) == 120
    assert Parrhesia.Config.get([:features, :nip_50_search]) == true
    assert Parrhesia.Config.get([:features, :marmot_push_notifications]) == false
  end

  test "returns default for unknown keys" do
    assert Parrhesia.Config.get([:limits, :unknown_limit], :missing) == :missing
  end
end
