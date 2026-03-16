defmodule Parrhesia.Storage.ACL do
  @moduledoc """
  Storage callbacks for persisted ACL rules.
  """

  @type context :: map()
  @type rule :: map()
  @type opts :: keyword()
  @type reason :: term()

  @callback put_rule(context(), rule()) :: {:ok, rule()} | {:error, reason()}
  @callback delete_rule(context(), map()) :: :ok | {:error, reason()}
  @callback list_rules(context(), opts()) :: {:ok, [rule()]} | {:error, reason()}
end
