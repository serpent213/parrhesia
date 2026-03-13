defmodule Parrhesia.Repo do
  @moduledoc """
  PostgreSQL repository for storage adapter persistence.
  """

  use Ecto.Repo,
    otp_app: :parrhesia,
    adapter: Ecto.Adapters.Postgres
end
