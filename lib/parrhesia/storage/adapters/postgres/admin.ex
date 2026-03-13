defmodule Parrhesia.Storage.Adapters.Postgres.Admin do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Admin`.

  Implementation is intentionally staged; callbacks currently return
  `{:error, :not_implemented}` until NIP-86 management storage lands.
  """

  @behaviour Parrhesia.Storage.Admin

  @impl true
  def execute(_context, _method, _params), do: {:error, :not_implemented}

  @impl true
  def append_audit_log(_context, _entry), do: {:error, :not_implemented}

  @impl true
  def list_audit_logs(_context, _opts), do: {:error, :not_implemented}
end
