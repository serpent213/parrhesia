defmodule Parrhesia.Repo.Migrations.AddBinaryIdentifierLengthConstraints do
  use Ecto.Migration

  @constraints [
    {"event_ids", "event_ids_id_length_check", "octet_length(id) = 32"},
    {"events", "events_id_length_check", "octet_length(id) = 32"},
    {"events", "events_pubkey_length_check", "octet_length(pubkey) = 32"},
    {"events", "events_sig_length_check", "octet_length(sig) = 64"},
    {"event_tags", "event_tags_event_id_length_check", "octet_length(event_id) = 32"},
    {"replaceable_event_state", "replaceable_event_state_pubkey_length_check",
     "octet_length(pubkey) = 32"},
    {"replaceable_event_state", "replaceable_event_state_event_id_length_check",
     "octet_length(event_id) = 32"},
    {"addressable_event_state", "addressable_event_state_pubkey_length_check",
     "octet_length(pubkey) = 32"},
    {"addressable_event_state", "addressable_event_state_event_id_length_check",
     "octet_length(event_id) = 32"},
    {"banned_pubkeys", "banned_pubkeys_pubkey_length_check", "octet_length(pubkey) = 32"},
    {"allowed_pubkeys", "allowed_pubkeys_pubkey_length_check", "octet_length(pubkey) = 32"},
    {"banned_events", "banned_events_event_id_length_check", "octet_length(event_id) = 32"},
    {"group_memberships", "group_memberships_pubkey_length_check", "octet_length(pubkey) = 32"},
    {"group_roles", "group_roles_pubkey_length_check", "octet_length(pubkey) = 32"},
    {"management_audit_logs", "management_audit_logs_actor_pubkey_length_check",
     "actor_pubkey IS NULL OR octet_length(actor_pubkey) = 32"},
    {"acl_rules", "acl_rules_principal_length_check", "octet_length(principal) = 32"}
  ]

  def up do
    Enum.each(@constraints, fn {table_name, constraint_name, expression} ->
      execute("""
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{constraint_name}
      CHECK (#{expression})
      """)
    end)
  end

  def down do
    Enum.each(@constraints, fn {table_name, constraint_name, _expression} ->
      execute("""
      ALTER TABLE #{table_name}
      DROP CONSTRAINT #{constraint_name}
      """)
    end)
  end
end
