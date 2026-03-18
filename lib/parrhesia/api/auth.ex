defmodule Parrhesia.API.Auth do
  @moduledoc """
  Public helpers for event validation and NIP-98 HTTP authentication.

  This module is intended for callers that need a programmatic API surface:

  - `validate_event/1` returns validator reason atoms.
  - `compute_event_id/1` computes the canonical Nostr event id.
  - `validate_nip98/3` and `validate_nip98/4` turn an `Authorization` header into a
    shared auth context that can be reused by the rest of the API surface.

  For transport-facing validation messages, see `Parrhesia.Protocol.validate_event/1`.
  """

  alias Parrhesia.API.Auth.Context
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Auth.Nip98
  alias Parrhesia.Protocol.EventValidator

  @doc """
  Validates a Nostr event and returns validator-friendly error atoms.

  This is the low-level validation entrypoint used by the API surface. Unlike
  `Parrhesia.Protocol.validate_event/1`, it preserves the raw validator reason so callers
  can branch on it directly.
  """
  @spec validate_event(map()) :: :ok | {:error, term()}
  def validate_event(event), do: EventValidator.validate(event)

  @doc """
  Computes the canonical Nostr event id for an event payload.

  The event does not need to be persisted first. This is useful when building or signing
  events locally.
  """
  @spec compute_event_id(map()) :: String.t()
  def compute_event_id(event), do: EventValidator.compute_id(event)

  @doc """
  Validates a NIP-98 `Authorization` header using default options.
  """
  @spec validate_nip98(String.t() | nil, String.t(), String.t()) ::
          {:ok, Context.t()} | {:error, term()}
  def validate_nip98(authorization, method, url) do
    validate_nip98(authorization, method, url, [])
  end

  @doc """
  Validates a NIP-98 `Authorization` header and returns a shared auth context.

  The returned `Parrhesia.API.Auth.Context` includes:

  - the decoded auth event
  - the authenticated pubkey
  - a `Parrhesia.API.RequestContext` with `caller: :http`

  Supported options are forwarded to `Parrhesia.Auth.Nip98.validate_authorization_header/4`,
  including `:max_age_seconds` and `:replay_cache`.
  """
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
