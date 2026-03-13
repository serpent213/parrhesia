defmodule Parrhesia.Storage.Events do
  @moduledoc """
  Storage callbacks for event persistence and query operations.
  """

  @type context :: map()
  @type event_id :: binary()
  @type event :: map()
  @type filter :: map()
  @type query_opts :: keyword()
  @type count_result :: non_neg_integer() | %{optional(atom()) => term()}
  @type reason :: term()

  @callback put_event(context(), event()) :: {:ok, event()} | {:error, reason()}
  @callback get_event(context(), event_id()) :: {:ok, event() | nil} | {:error, reason()}
  @callback query(context(), [filter()], query_opts()) :: {:ok, [event()]} | {:error, reason()}
  @callback count(context(), [filter()], query_opts()) ::
              {:ok, count_result()} | {:error, reason()}
  @callback delete_by_request(context(), event()) :: {:ok, non_neg_integer()} | {:error, reason()}
  @callback vanish(context(), event()) :: {:ok, non_neg_integer()} | {:error, reason()}
  @callback purge_expired(query_opts()) :: {:ok, non_neg_integer()} | {:error, reason()}
end
