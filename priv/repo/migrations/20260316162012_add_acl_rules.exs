defmodule Parrhesia.Repo.Migrations.AddAclRules do
  use Ecto.Migration

  def change do
    create table(:acl_rules) do
      add(:principal_type, :string, null: false)
      add(:principal, :binary, null: false)
      add(:capability, :string, null: false)
      add(:match, :map, null: false, default: %{})
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:acl_rules, [:principal_type, :principal, :capability]))
  end
end
