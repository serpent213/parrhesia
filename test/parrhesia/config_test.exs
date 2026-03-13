defmodule Parrhesia.ConfigTest do
  use ExUnit.Case, async: true

  test "returns configured relay limits/policies/features" do
    assert Parrhesia.Config.get([:limits, :max_frame_bytes]) == 1_048_576
    assert Parrhesia.Config.get([:limits, :max_event_bytes]) == 262_144
    assert Parrhesia.Config.get([:limits, :max_event_future_skew_seconds]) == 900
    assert Parrhesia.Config.get([:limits, :max_outbound_queue]) == 256
    assert Parrhesia.Config.get([:policies, :auth_required_for_writes]) == false
    assert Parrhesia.Config.get([:features, :nip_ee_mls]) == false
  end

  test "returns default for unknown keys" do
    assert Parrhesia.Config.get([:limits, :unknown_limit], :missing) == :missing
  end
end
