defmodule Parrhesia.Web.IPEventIngestLimiterTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Web.IPEventIngestLimiter

  test "allows events up to the configured per-IP window cap" do
    limiter =
      start_supervised!(
        {IPEventIngestLimiter, name: nil, max_events_per_window: 2, window_seconds: 60}
      )

    assert :ok = IPEventIngestLimiter.allow("203.0.113.10", limiter)
    assert :ok = IPEventIngestLimiter.allow("203.0.113.10", limiter)
    assert {:error, :ip_event_rate_limited} = IPEventIngestLimiter.allow("203.0.113.10", limiter)
    assert :ok = IPEventIngestLimiter.allow("203.0.113.11", limiter)
  end

  test "allows events without a remote IP" do
    limiter =
      start_supervised!(
        {IPEventIngestLimiter, name: nil, max_events_per_window: 1, window_seconds: 60}
      )

    assert :ok = IPEventIngestLimiter.allow(nil, limiter)
  end
end
