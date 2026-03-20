# Changelog

All notable changes to this project will be documented in this file.

## [0.7.0] - 2026-03-20

First beta release!

### Added
- Configurable WebSocket keepalive support in `Parrhesia.Web.Connection`:
  - server-initiated `PING` frames
  - `PONG` timeout handling with connection close on timeout
- New runtime limit settings:
  - `:websocket_ping_interval_seconds` (`PARRHESIA_LIMITS_WEBSOCKET_PING_INTERVAL_SECONDS`)
  - `:websocket_pong_timeout_seconds` (`PARRHESIA_LIMITS_WEBSOCKET_PONG_TIMEOUT_SECONDS`)

### Changed
- NIP-42 challenge validation now uses constant-time comparison via `Plug.Crypto.secure_compare/2`.
