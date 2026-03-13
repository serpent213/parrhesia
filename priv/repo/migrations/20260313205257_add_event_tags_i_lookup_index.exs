defmodule Parrhesia.Repo.Migrations.AddEventTagsILookupIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX event_tags_i_value_created_at_idx ON event_tags (value, event_created_at DESC) WHERE name = 'i'"
    )
  end

  def down do
    execute("DROP INDEX event_tags_i_value_created_at_idx")
  end
end
