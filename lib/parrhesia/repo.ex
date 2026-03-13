defmodule Parrhesia.Repo do
  @moduledoc """
  PostgreSQL repository for storage adapter persistence.

  Note: the repo is not yet started by the supervision tree while the
  storage adapter is in staged implementation.
  """

  use Ecto.Repo,
    otp_app: :parrhesia,
    adapter: Ecto.Adapters.Postgres
end
