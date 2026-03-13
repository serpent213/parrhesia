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
