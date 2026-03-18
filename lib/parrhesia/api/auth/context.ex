defmodule Parrhesia.API.Auth.Context do
  @moduledoc """
  Authenticated request details returned by shared auth helpers.

  This is the higher-level result returned by `Parrhesia.API.Auth.validate_nip98/3` and
  `validate_nip98/4`. The nested `request_context` is ready to be passed into the rest of the
  public API surface.
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
