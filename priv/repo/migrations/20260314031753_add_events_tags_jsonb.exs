defmodule Parrhesia.Repo.Migrations.AddEventsTagsJsonb do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE events ADD COLUMN tags jsonb NOT NULL DEFAULT '[]'::jsonb")

    execute("""
    UPDATE events AS event
    SET tags = COALESCE(
      (
        SELECT jsonb_agg(jsonb_build_array(tag.name, tag.value) ORDER BY tag.idx)
        FROM event_tags AS tag
        WHERE tag.event_created_at = event.created_at
          AND tag.event_id = event.id
      ),
      '[]'::jsonb
    )
    """)
  end

  def down do
    execute("ALTER TABLE events DROP COLUMN tags")
  end
end
