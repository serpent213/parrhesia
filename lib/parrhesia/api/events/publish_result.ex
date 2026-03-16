defmodule Parrhesia.API.Events.PublishResult do
  @moduledoc """
  Result shape for event publish attempts.
  """

  defstruct [:event_id, :accepted, :message, :reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          accepted: boolean(),
          message: String.t(),
          reason: term()
        }
end
