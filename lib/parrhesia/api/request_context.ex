defmodule Parrhesia.API.RequestContext do
  @moduledoc """
  Shared request context used across API and policy surfaces.

  This struct carries caller identity and transport metadata through authorization and storage
  boundaries.

  The most important field for external callers is `authenticated_pubkeys`. For example:

  - `Parrhesia.API.Events` uses it for read and write policy checks
  - `Parrhesia.API.Stream` uses it for subscription authorization
  - `Parrhesia.API.ACL` uses it when evaluating protected sync traffic
  """

  defstruct authenticated_pubkeys: MapSet.new(),
            actor: nil,
            caller: :local,
            remote_ip: nil,
            subscription_id: nil,
            peer_id: nil,
            transport_identity: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          authenticated_pubkeys: MapSet.t(String.t()),
          actor: term(),
          caller: atom(),
          remote_ip: String.t() | nil,
          subscription_id: String.t() | nil,
          peer_id: String.t() | nil,
          transport_identity: map() | nil,
          metadata: map()
        }

  @doc """
  Merges arbitrary metadata into the context.

  Existing keys are overwritten by the incoming map.
  """
  @spec put_metadata(t(), map()) :: t()
  def put_metadata(%__MODULE__{} = context, metadata) when is_map(metadata) do
    %__MODULE__{context | metadata: Map.merge(context.metadata, metadata)}
  end
end
