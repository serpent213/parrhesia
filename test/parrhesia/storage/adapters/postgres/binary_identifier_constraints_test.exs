defmodule Parrhesia.Storage.Adapters.Postgres.BinaryIdentifierConstraintsTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Repo

  test "events rejects malformed binary identifier lengths at the database layer" do
    assert_check_violation(
      """
      INSERT INTO events (created_at, id, pubkey, kind, content, sig, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
      """,
      [
        1_700_123_456,
        :binary.copy(<<0x10>>, 31),
        :binary.copy(<<0x20>>, 32),
        1,
        "invalid event id length",
        :binary.copy(<<0x30>>, 64)
      ],
      "events_id_length_check"
    )
  end

  test "management audit logs allow nil actor pubkeys but reject malformed ones" do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               """
               INSERT INTO management_audit_logs (actor_pubkey, method, params, inserted_at)
               VALUES ($1, $2, $3, NOW())
               """,
               [nil, "ping", %{}]
             )

    assert_check_violation(
      """
      INSERT INTO management_audit_logs (actor_pubkey, method, params, inserted_at)
      VALUES ($1, $2, $3, NOW())
      """,
      [:binary.copy(<<0x40>>, 31), "ping", %{}],
      "management_audit_logs_actor_pubkey_length_check"
    )
  end

  test "acl rules reject malformed principal lengths at the database layer" do
    assert_check_violation(
      """
      INSERT INTO acl_rules (principal_type, principal, capability, match, inserted_at)
      VALUES ($1, $2, $3, $4, NOW())
      """,
      ["pubkey", :binary.copy(<<0x50>>, 31), "sync_read", %{}],
      "acl_rules_principal_length_check"
    )
  end

  defp assert_check_violation(sql, params, constraint_name) do
    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: ^constraint_name}
            }} = Repo.query(sql, params)
  end
end
