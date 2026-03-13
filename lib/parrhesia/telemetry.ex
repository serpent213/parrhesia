defmodule Parrhesia.Telemetry do
  @moduledoc """
  Supervision entrypoint and helpers for relay telemetry.
  """

  use Supervisor

  import Telemetry.Metrics

  @prometheus_reporter __MODULE__.Prometheus

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, name: @prometheus_reporter, metrics: metrics()},
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec prometheus_reporter() :: atom()
  def prometheus_reporter, do: @prometheus_reporter

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      distribution("parrhesia.ingest.duration.ms",
        event_name: [:parrhesia, :ingest, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.query.duration.ms",
        event_name: [:parrhesia, :query, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.fanout.duration.ms",
        event_name: [:parrhesia, :fanout, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      last_value("parrhesia.connection.outbound_queue.depth",
        event_name: [:parrhesia, :connection, :outbound_queue],
        measurement: :depth,
        reporter_options: [prometheus_type: :gauge]
      ),
      counter("parrhesia.connection.outbound_queue.overflow.count",
        event_name: [:parrhesia, :connection, :outbound_queue, :overflow],
        measurement: :count
      ),
      last_value("parrhesia.vm.memory.total.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :total,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      )
    ]
  end

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event_name, measurements, metadata \\ %{})
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  defp periodic_measurements do
    [
      {__MODULE__, :emit_vm_memory, []}
    ]
  end

  @doc false
  def emit_vm_memory do
    total = :erlang.memory(:total)
    emit([:parrhesia, :vm, :memory], %{total: total}, %{})
  end
end
