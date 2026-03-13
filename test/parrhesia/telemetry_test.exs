defmodule Parrhesia.TelemetryTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Telemetry

  test "exposes Marmot-focused telemetry metrics" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:parrhesia, :ingest, :duration, :ms] in metric_names
    assert [:parrhesia, :query, :duration, :ms] in metric_names
    assert [:parrhesia, :fanout, :duration, :ms] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :depth] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :pressure] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :pressure_events, :count] in metric_names
  end

  test "emit/3 accepts traffic-class metadata" do
    assert :ok =
             Telemetry.emit(
               [:parrhesia, :ingest, :stop],
               %{duration: 1},
               %{traffic_class: :marmot}
             )
  end
end
