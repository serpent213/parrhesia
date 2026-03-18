defmodule Parrhesia.API.Events.PublishResult do
  @moduledoc """
  Result shape for event publish attempts.

  This mirrors relay `OK` semantics:

  - `accepted: true` means the event was accepted
  - `accepted: false` means the event was rejected or identified as a duplicate

  The surrounding call still returns `{:ok, result}` in both cases so callers can surface the
  rejection message without treating it as a transport or process failure.
  """

  defstruct [:event_id, :accepted, :message, :reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          accepted: boolean(),
          message: String.t(),
          reason: term()
        }
end
