defmodule Parrhesia.API.RequestContext do
  @moduledoc """
  Shared request context used across API and policy surfaces.
  """

  defstruct authenticated_pubkeys: MapSet.new(),
            actor: nil,
            caller: :local,
            remote_ip: nil,
            subscription_id: nil,
            peer_id: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          authenticated_pubkeys: MapSet.t(String.t()),
          actor: term(),
          caller: atom(),
          remote_ip: String.t() | nil,
          subscription_id: String.t() | nil,
          peer_id: String.t() | nil,
          metadata: map()
        }

  @spec put_metadata(t(), map()) :: t()
  def put_metadata(%__MODULE__{} = context, metadata) when is_map(metadata) do
    %__MODULE__{context | metadata: Map.merge(context.metadata, metadata)}
  end
end
