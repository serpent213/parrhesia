defmodule Parrhesia.Storage.Admin do
  @moduledoc """
  Storage callbacks used by relay management endpoints (NIP-86 backing).
  """

  @type context :: map()
  @type method :: atom() | binary()
  @type params :: map()
  @type result :: map() | list() | term()
  @type audit_entry :: map()
  @type reason :: term()

  @callback execute(context(), method(), params()) :: {:ok, result()} | {:error, reason()}
  @callback append_audit_log(context(), audit_entry()) :: :ok | {:error, reason()}
  @callback list_audit_logs(context(), keyword()) :: {:ok, [audit_entry()]} | {:error, reason()}
end
