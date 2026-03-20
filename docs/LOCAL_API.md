# Parrhesia Local API

Parrhesia can run as a normal standalone relay application, but it also exposes a stable
in-process API for Elixir callers that want to embed the relay inside a larger OTP system.

This document describes that embedding surface. The runtime is pre-beta, so treat the API
as usable but not yet frozen.

## What embedding means today

Embedding currently means:

- the host app adds `:parrhesia` as a dependency and OTP application
- the host app provides `config :parrhesia, ...` explicitly
- the host app migrates the Parrhesia database schema
- callers interact with the relay through `Parrhesia.API.*`
- host-managed HTTP/WebSocket ingress is mounted through `Parrhesia.Plug`

Current operational assumptions:

- Parrhesia runs one runtime per BEAM node
- core processes use global module names such as `Parrhesia.Config` and `Parrhesia.Web.Endpoint`
- the config defaults in this repo's `config/*.exs` are not imported automatically by a host app

If you want multiple isolated relay instances inside one VM, Parrhesia does not support that
cleanly yet.

## Minimal host setup

Add the dependency in your host app:

```elixir
defp deps do
  [
    {:parrhesia, path: "../parrhesia"}
  ]
end
```

Configure the runtime in your host app. At minimum you should carry over:

```elixir
import Config

config :postgrex, :json_library, JSON

config :parrhesia,
  relay_url: "wss://relay.example.com/relay",
  listeners: %{},
  storage: [backend: :postgres]

config :parrhesia, Parrhesia.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 10,
  types: Parrhesia.PostgresTypes

config :parrhesia, Parrhesia.ReadRepo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 10,
  types: Parrhesia.PostgresTypes

config :parrhesia, ecto_repos: [Parrhesia.Repo]
```

Notes:

- `listeners: %{}` is the official embedding pattern when your host app owns the HTTPS edge.
- `listeners: %{}` disables Parrhesia-managed ingress (`/relay`, `/management`, `/metrics`, etc.).
- Mount `Parrhesia.Plug` from the host app when you still want Parrhesia ingress behind that same
  HTTPS edge.
- `Parrhesia.Web.*` modules are internal runtime wiring. Treat `Parrhesia.Plug` as the stable
  mount API.
- If you prefer Parrhesia-managed ingress instead, copy the listener shape from the config
  reference in [README.md](../README.md).
- Production runtime overrides still use the `PARRHESIA_*` environment variables described in
  [README.md](../README.md).

Migrate before serving traffic:

```elixir
Parrhesia.Release.migrate()
```

In development, `mix ecto.migrate -r Parrhesia.Repo` works too.

## Mounting `Parrhesia.Plug` from a host app

When `listeners: %{}` is set, you can still expose Parrhesia ingress by mounting `Parrhesia.Plug`
in your host endpoint/router and passing an explicit listener config:

```elixir
forward "/nostr", Parrhesia.Plug,
  listener: %{
    id: :public,
    transport: %{scheme: :https, tls: %{mode: :proxy_terminated}},
    proxy: %{trusted_cidrs: ["10.0.0.0/8"], honor_x_forwarded_for: true},
    features: %{
      nostr: %{enabled: true},
      admin: %{enabled: true},
      metrics: %{enabled: true, access: %{private_networks_only: true}}
    }
  }
```

Use the same listener schema documented in [README.md](../README.md).

## Starting the runtime

In the common case, letting OTP start the `:parrhesia` application is enough.

If you need to start the runtime explicitly under your own supervision tree, use
`Parrhesia.Runtime`:

```elixir
children = [
  {Parrhesia.Runtime, name: Parrhesia.Supervisor}
]
```

## Primary modules

The in-process surface is centered on these modules:

- `Parrhesia.API.Events` for publish, query, and count
- `Parrhesia.API.Stream` for REQ-like local subscriptions
- `Parrhesia.API.Auth` for event validation and NIP-98 auth parsing
- `Parrhesia.API.Admin` for management operations
- `Parrhesia.API.Identity` for relay-owned key management
- `Parrhesia.API.ACL` for protected sync ACLs
- `Parrhesia.API.Sync` for outbound relay sync management

Generated ExDoc groups these modules under `Embedded API`.

## Request context

Most calls take a `Parrhesia.API.RequestContext`. This carries authenticated pubkeys and
caller metadata through policy checks.

```elixir
%Parrhesia.API.RequestContext{
  caller: :local,
  authenticated_pubkeys: MapSet.new()
}
```

If your host app has already authenticated a user or peer, put that pubkey into
`authenticated_pubkeys` before calling the API.

## Example

```elixir
alias Parrhesia.API.Events
alias Parrhesia.API.RequestContext
alias Parrhesia.API.Stream

context = %RequestContext{caller: :local}

{:ok, publish_result} = Events.publish(event, context: context)
{:ok, events} = Events.query([%{"kinds" => [1]}], context: context)
{:ok, ref} = Stream.subscribe(self(), "local-sub", [%{"kinds" => [1]}], context: context)

receive do
  {:parrhesia, :event, ^ref, "local-sub", event} -> event
  {:parrhesia, :eose, ^ref, "local-sub"} -> :ok
end

:ok = Stream.unsubscribe(ref)
```

## Where to look next

- [README.md](../README.md) for setup and the full config reference
- [docs/SYNC.md](./SYNC.md) for relay-to-relay sync semantics
- module docs under `Parrhesia.API.*` for per-function behavior
