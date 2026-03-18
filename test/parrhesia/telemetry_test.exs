defmodule Parrhesia.TelemetryTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Telemetry

  test "exposes Marmot-focused telemetry metrics" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:parrhesia, :ingest, :duration, :ms] in metric_names
    assert [:parrhesia, :query, :duration, :ms] in metric_names
    assert [:parrhesia, :fanout, :duration, :ms] in metric_names
    assert [:parrhesia, :fanout, :events_enqueued, :count] in metric_names
    assert [:parrhesia, :ingest, :events, :count] in metric_names
    assert [:parrhesia, :query, :requests, :count] in metric_names
    assert [:parrhesia, :query, :results, :count] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :depth] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :drained_frames, :count] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :dropped_events, :count] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :pressure] in metric_names
    assert [:parrhesia, :connection, :outbound_queue, :pressure_events, :count] in metric_names
    assert [:parrhesia, :listener, :connections, :active] in metric_names
    assert [:parrhesia, :listener, :subscriptions, :active] in metric_names
    assert [:parrhesia, :rate_limit, :hits, :count] in metric_names
    assert [:parrhesia, :db, :query, :count] in metric_names
    assert [:parrhesia, :process, :mailbox, :depth] in metric_names
    assert [:parrhesia, :maintenance, :purge_expired, :events, :count] in metric_names

    assert [:parrhesia, :maintenance, :partition_retention, :dropped_partitions, :count] in metric_names

    assert [:parrhesia, :vm, :memory, :binary, :bytes] in metric_names
  end

  test "emit/3 accepts traffic-class metadata" do
    assert :ok =
             Telemetry.emit(
               [:parrhesia, :ingest, :stop],
               %{duration: 1},
               %{traffic_class: :marmot}
             )
  end

  test "emit_process_mailbox_depth/2 tags process type" do
    handler_id = "telemetry-mailbox-depth-test"

    :ok =
      :telemetry.attach(
        handler_id,
        [:parrhesia, :process, :mailbox],
        fn _event_name, measurements, metadata, test_pid ->
          send(test_pid, {:mailbox_depth, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.emit_process_mailbox_depth(:connection)

    assert_receive {:mailbox_depth, %{depth: depth}, %{process_type: :connection}}
    assert is_integer(depth)
    assert depth >= 0
  end
end
