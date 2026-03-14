defmodule Parrhesia.Repo.Migrations.CreateRelayStorage do
  use Ecto.Migration

  def up do
    create table(:event_ids, primary_key: false) do
      add(:id, :binary, primary_key: true)
      add(:created_at, :bigint, null: false)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:events, primary_key: false, options: "PARTITION BY RANGE (created_at)") do
      add(:created_at, :bigint, primary_key: true)
      add(:id, :binary, primary_key: true)
      add(:pubkey, :binary, null: false)
      add(:kind, :integer, null: false)
      add(:content, :text, null: false)
      add(:sig, :binary, null: false)
      add(:d_tag, :text)
      add(:deleted_at, :bigint)
      add(:expires_at, :bigint)
      timestamps(type: :utc_datetime_usec)
    end

    execute("CREATE TABLE events_default PARTITION OF events DEFAULT")

    execute("CREATE INDEX events_kind_created_at_idx ON events (kind, created_at DESC)")
    execute("CREATE INDEX events_pubkey_created_at_idx ON events (pubkey, created_at DESC)")
    execute("CREATE INDEX events_created_at_idx ON events (created_at DESC)")
    create(index(:events, [:id]))
    create(index(:events, [:expires_at], where: "expires_at IS NOT NULL"))
    create(index(:events, [:deleted_at], where: "deleted_at IS NOT NULL"))

    create table(:event_tags,
             primary_key: false,
             options: "PARTITION BY RANGE (event_created_at)"
           ) do
      add(:event_created_at, :bigint, null: false)
      add(:event_id, :binary, null: false)
      add(:name, :string, null: false)
      add(:value, :string, null: false)
      add(:idx, :integer, null: false)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    execute("CREATE TABLE event_tags_default PARTITION OF event_tags DEFAULT")

    execute("""
    ALTER TABLE event_tags
    ADD CONSTRAINT event_tags_event_fk
    FOREIGN KEY (event_created_at, event_id)
    REFERENCES events (created_at, id)
    ON DELETE CASCADE
    """)

    create(unique_index(:event_tags, [:event_created_at, :event_id, :idx]))

    execute(
      "CREATE INDEX event_tags_name_value_created_at_idx ON event_tags (name, value, event_created_at DESC)"
    )

    create(index(:event_tags, [:event_id]))

    create table(:replaceable_event_state, primary_key: false) do
      add(:pubkey, :binary, primary_key: true)
      add(:kind, :integer, primary_key: true)
      add(:event_created_at, :bigint, null: false)
      add(:event_id, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:addressable_event_state, primary_key: false) do
      add(:pubkey, :binary, primary_key: true)
      add(:kind, :integer, primary_key: true)
      add(:d_tag, :text, primary_key: true)
      add(:event_created_at, :bigint, null: false)
      add(:event_id, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:banned_pubkeys, primary_key: false) do
      add(:pubkey, :binary, primary_key: true)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:allowed_pubkeys, primary_key: false) do
      add(:pubkey, :binary, primary_key: true)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:banned_events, primary_key: false) do
      add(:event_id, :binary, primary_key: true)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:blocked_ips, primary_key: false) do
      add(:ip, :inet, primary_key: true)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:relay_groups, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create table(:group_memberships, primary_key: false) do
      add(
        :group_id,
        references(:relay_groups, column: :group_id, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:pubkey, :binary, primary_key: true)
      add(:role, :string, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:group_memberships, [:pubkey]))

    create table(:group_roles, primary_key: false) do
      add(
        :group_id,
        references(:relay_groups, column: :group_id, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:pubkey, :binary, primary_key: true)
      add(:role, :string, primary_key: true)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create table(:management_audit_logs) do
      add(:actor_pubkey, :binary)
      add(:method, :string, null: false)
      add(:params, :map, null: false, default: %{})
      add(:result, :map)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:management_audit_logs, [:actor_pubkey, :inserted_at]))
    create(index(:management_audit_logs, [:method, :inserted_at]))
  end

  def down do
    drop(table(:management_audit_logs))
    drop(table(:group_roles))
    drop(table(:group_memberships))
    drop(table(:relay_groups))
    drop(table(:blocked_ips))
    drop(table(:banned_events))
    drop(table(:allowed_pubkeys))
    drop(table(:banned_pubkeys))
    drop(table(:addressable_event_state))
    drop(table(:replaceable_event_state))

    execute("DROP TABLE event_tags_default")
    drop(table(:event_tags))

    execute("DROP TABLE events_default")
    drop(table(:events))

    drop(table(:event_ids))
  end
end
