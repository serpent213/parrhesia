defmodule Parrhesia do
  @moduledoc """
  Parrhesia is a Nostr relay runtime that can run standalone or as an embedded OTP service.

  For embedded use, the main developer-facing surface is `Parrhesia.API.*`.
  For host-managed HTTP/WebSocket ingress mounting, use `Parrhesia.Plug`.
  Start with:

  - `Parrhesia.API.Events`
  - `Parrhesia.API.Stream`
  - `Parrhesia.API.Admin`
  - `Parrhesia.API.Identity`
  - `Parrhesia.API.ACL`
  - `Parrhesia.API.Sync`
  - `Parrhesia.Plug`

  The host application is responsible for:

  - setting `config :parrhesia, ...`
  - migrating the configured Parrhesia repos
  - deciding whether to expose listeners or use only the in-process API

  See `README.md` and `docs/LOCAL_API.md` for the embedding model and configuration guide.
  """

  @doc false
  def hello do
    :world
  end
end
