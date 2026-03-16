defmodule Parrhesia.API.Auth.Context do
  @moduledoc """
  Authenticated request details returned by shared auth helpers.
  """

  alias Parrhesia.API.RequestContext

  defstruct auth_event: nil,
            pubkey: nil,
            request_context: %RequestContext{},
            metadata: %{}

  @type t :: %__MODULE__{
          auth_event: map() | nil,
          pubkey: String.t() | nil,
          request_context: RequestContext.t(),
          metadata: map()
        }
end
