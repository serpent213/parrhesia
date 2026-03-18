defmodule Parrhesia.ReadRepo do
  @moduledoc """
  PostgreSQL repository dedicated to read-heavy workloads when a separate read pool is enabled.
  """

  use Ecto.Repo,
    otp_app: :parrhesia,
    adapter: Ecto.Adapters.Postgres
end
