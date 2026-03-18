defmodule Parrhesia.Repo.Migrations.AddNip50FtsAndTrigramSearch do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX events_content_fts_idx
    ON events
    USING GIN (to_tsvector('simple', content))
    WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX events_content_trgm_idx
    ON events
    USING GIN (content gin_trgm_ops)
    WHERE deleted_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS events_content_trgm_idx")
    execute("DROP INDEX IF EXISTS events_content_fts_idx")
    execute("DROP EXTENSION IF EXISTS pg_trgm")
  end
end
