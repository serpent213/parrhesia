defmodule Parrhesia.Web.EventIngestLimiterTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Web.EventIngestLimiter

  test "allows events up to the configured relay-wide window cap" do
    limiter =
      start_supervised!(
        {EventIngestLimiter, name: nil, max_events_per_window: 2, window_seconds: 60}
      )

    assert :ok = EventIngestLimiter.allow(limiter)
    assert :ok = EventIngestLimiter.allow(limiter)
    assert {:error, :relay_event_rate_limited} = EventIngestLimiter.allow(limiter)
  end
end
