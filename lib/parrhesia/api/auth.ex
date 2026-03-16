defmodule Parrhesia.API.Auth do
  @moduledoc """
  Shared auth and event validation helpers.
  """

  alias Parrhesia.API.Auth.Context
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Auth.Nip98
  alias Parrhesia.Protocol.EventValidator

  @spec validate_event(map()) :: :ok | {:error, term()}
  def validate_event(event), do: EventValidator.validate(event)

  @spec compute_event_id(map()) :: String.t()
  def compute_event_id(event), do: EventValidator.compute_id(event)

  @spec validate_nip98(String.t() | nil, String.t(), String.t()) ::
          {:ok, Context.t()} | {:error, term()}
  def validate_nip98(authorization, method, url) do
    validate_nip98(authorization, method, url, [])
  end

  @spec validate_nip98(String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, Context.t()} | {:error, term()}
  def validate_nip98(authorization, method, url, opts)
      when is_binary(method) and is_binary(url) and is_list(opts) do
    with {:ok, auth_event} <-
           Nip98.validate_authorization_header(authorization, method, url, opts),
         pubkey when is_binary(pubkey) <- Map.get(auth_event, "pubkey") do
      {:ok,
       %Context{
         auth_event: auth_event,
         pubkey: pubkey,
         request_context: %RequestContext{
           authenticated_pubkeys: MapSet.new([pubkey]),
           caller: :http
         },
         metadata: %{
           method: method,
           url: url
         }
       }}
    else
      nil -> {:error, :invalid_event}
      {:error, reason} -> {:error, reason}
    end
  end
end
