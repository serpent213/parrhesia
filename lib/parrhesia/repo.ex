defmodule Parrhesia.Repo do
  @moduledoc """
  PostgreSQL repository for write traffic and storage adapter persistence.

  Separated from `Parrhesia.ReadRepo` so that ingest writes and read-heavy
  queries use independent connection pools.
  """

  use Ecto.Repo,
    otp_app: :parrhesia,
    adapter: Ecto.Adapters.Postgres
end
