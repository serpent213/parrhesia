defmodule Parrhesia.Telemetry do
  @moduledoc """
  Supervision entrypoint and helpers for relay telemetry.

  Starts the Prometheus reporter and telemetry poller as supervised children.
  All relay metrics are namespaced under `parrhesia.*` and exposed through the
  `/metrics` endpoint in Prometheus exposition format.
  """

  use Supervisor

  import Telemetry.Metrics

  @repo_query_handler_id "parrhesia-repo-query-handler"
  @prometheus_reporter __MODULE__.Prometheus

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    :ok = attach_repo_query_handlers()

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
      counter("parrhesia.ingest.events.count",
        event_name: [:parrhesia, :ingest, :result],
        measurement: :count,
        tags: [:traffic_class, :outcome, :reason],
        tag_values: &ingest_result_tag_values/1
      ),
      distribution("parrhesia.ingest.duration.ms",
        event_name: [:parrhesia, :ingest, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1,
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      counter("parrhesia.query.requests.count",
        event_name: [:parrhesia, :query, :result],
        measurement: :count,
        tags: [:traffic_class, :operation, :outcome],
        tag_values: &query_result_tag_values/1
      ),
      distribution("parrhesia.query.duration.ms",
        event_name: [:parrhesia, :query, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:traffic_class, :operation],
        tag_values: &query_stop_tag_values/1,
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.query.results.count",
        event_name: [:parrhesia, :query, :stop],
        measurement: :result_count,
        tags: [:traffic_class, :operation],
        tag_values: &query_stop_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]]
      ),
      distribution("parrhesia.fanout.duration.ms",
        event_name: [:parrhesia, :fanout, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1,
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      counter("parrhesia.fanout.events_considered.count",
        event_name: [:parrhesia, :fanout, :stop],
        measurement: :considered,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1
      ),
      counter("parrhesia.fanout.events_enqueued.count",
        event_name: [:parrhesia, :fanout, :stop],
        measurement: :enqueued,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1
      ),
      distribution("parrhesia.fanout.batch_size",
        event_name: [:parrhesia, :fanout, :stop],
        measurement: :enqueued,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      last_value("parrhesia.connection.outbound_queue.depth",
        event_name: [:parrhesia, :connection, :outbound_queue],
        measurement: :depth,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.connection.outbound_queue.pressure",
        event_name: [:parrhesia, :connection, :outbound_queue],
        measurement: :pressure,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1,
        reporter_options: [prometheus_type: :gauge]
      ),
      counter("parrhesia.connection.outbound_queue.pressure_events.count",
        event_name: [:parrhesia, :connection, :outbound_queue, :pressure],
        measurement: :count,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1
      ),
      counter("parrhesia.connection.outbound_queue.overflow.count",
        event_name: [:parrhesia, :connection, :outbound_queue, :overflow],
        measurement: :count,
        tags: [:traffic_class],
        tag_values: &traffic_class_tag_values/1
      ),
      counter("parrhesia.connection.outbound_queue.drained_frames.count",
        event_name: [:parrhesia, :connection, :outbound_queue, :drain],
        measurement: :count
      ),
      distribution("parrhesia.connection.outbound_queue.drain_batch_size",
        event_name: [:parrhesia, :connection, :outbound_queue, :drain],
        measurement: :count,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250]]
      ),
      counter("parrhesia.connection.outbound_queue.dropped_events.count",
        event_name: [:parrhesia, :connection, :outbound_queue, :drop],
        measurement: :count,
        tags: [:strategy],
        tag_values: &strategy_tag_values/1
      ),
      last_value("parrhesia.listener.connections.active",
        event_name: [:parrhesia, :listener, :population],
        measurement: :connections,
        tags: [:listener_id],
        tag_values: &listener_tag_values/1,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.listener.subscriptions.active",
        event_name: [:parrhesia, :listener, :population],
        measurement: :subscriptions,
        tags: [:listener_id],
        tag_values: &listener_tag_values/1,
        reporter_options: [prometheus_type: :gauge]
      ),
      counter("parrhesia.rate_limit.hits.count",
        event_name: [:parrhesia, :rate_limit, :hit],
        measurement: :count,
        tags: [:scope, :traffic_class],
        tag_values: &rate_limit_tag_values/1
      ),
      last_value("parrhesia.process.mailbox.depth",
        event_name: [:parrhesia, :process, :mailbox],
        measurement: :depth,
        tags: [:process_type],
        tag_values: &process_tag_values/1,
        reporter_options: [prometheus_type: :gauge]
      ),
      counter("parrhesia.db.query.count",
        event_name: [:parrhesia, :db, :query],
        measurement: :count,
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1
      ),
      distribution("parrhesia.db.query.total_time.ms",
        event_name: [:parrhesia, :db, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1,
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.db.query.queue_time.ms",
        event_name: [:parrhesia, :db, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.db.query.query_time.ms",
        event_name: [:parrhesia, :db, :query],
        measurement: :query_time,
        unit: {:native, :millisecond},
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.db.query.decode_time.ms",
        event_name: [:parrhesia, :db, :query],
        measurement: :decode_time,
        unit: {:native, :millisecond},
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.db.query.idle_time.ms",
        event_name: [:parrhesia, :db, :query],
        measurement: :idle_time,
        unit: {:native, :millisecond},
        tags: [:repo_role],
        tag_values: &repo_query_tag_values/1,
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("parrhesia.maintenance.purge_expired.duration.ms",
        event_name: [:parrhesia, :maintenance, :purge_expired, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      counter("parrhesia.maintenance.purge_expired.events.count",
        event_name: [:parrhesia, :maintenance, :purge_expired, :stop],
        measurement: :purged_events
      ),
      distribution("parrhesia.maintenance.partition_retention.duration.ms",
        event_name: [:parrhesia, :maintenance, :partition_retention, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:status],
        tag_values: &status_tag_values/1,
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      counter("parrhesia.maintenance.partition_retention.dropped_partitions.count",
        event_name: [:parrhesia, :maintenance, :partition_retention, :stop],
        measurement: :dropped_partitions,
        tags: [:status],
        tag_values: &status_tag_values/1
      ),
      last_value("parrhesia.vm.memory.total.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :total,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.vm.memory.processes.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :processes,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.vm.memory.system.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :system,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.vm.memory.atom.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :atom,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.vm.memory.binary.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :binary,
        unit: :byte,
        reporter_options: [prometheus_type: :gauge]
      ),
      last_value("parrhesia.vm.memory.ets.bytes",
        event_name: [:parrhesia, :vm, :memory],
        measurement: :ets,
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

  @spec emit_process_mailbox_depth(atom(), map()) :: :ok
  def emit_process_mailbox_depth(process_type, metadata \\ %{})
      when is_atom(process_type) and is_map(metadata) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, depth} ->
        emit(
          [:parrhesia, :process, :mailbox],
          %{depth: depth},
          Map.put(metadata, :process_type, process_type)
        )

      nil ->
        :ok
    end
  end

  defp periodic_measurements do
    [
      {__MODULE__, :emit_vm_memory, []}
    ]
  end

  @doc false
  def emit_vm_memory do
    emit(
      [:parrhesia, :vm, :memory],
      %{
        total: :erlang.memory(:total),
        processes: :erlang.memory(:processes),
        system: :erlang.memory(:system),
        atom: :erlang.memory(:atom),
        binary: :erlang.memory(:binary),
        ets: :erlang.memory(:ets)
      },
      %{}
    )
  end

  defp traffic_class_tag_values(metadata) do
    traffic_class = metadata |> Map.get(:traffic_class, :generic) |> to_string()
    %{traffic_class: traffic_class}
  end

  defp ingest_result_tag_values(metadata) do
    %{
      traffic_class: metadata |> Map.get(:traffic_class, :generic) |> to_string(),
      outcome: metadata |> Map.get(:outcome, :unknown) |> to_string(),
      reason: metadata |> Map.get(:reason, :unknown) |> to_string()
    }
  end

  defp query_stop_tag_values(metadata) do
    %{
      traffic_class: metadata |> Map.get(:traffic_class, :generic) |> to_string(),
      operation: metadata |> Map.get(:operation, :query) |> to_string()
    }
  end

  defp query_result_tag_values(metadata) do
    %{
      traffic_class: metadata |> Map.get(:traffic_class, :generic) |> to_string(),
      operation: metadata |> Map.get(:operation, :query) |> to_string(),
      outcome: metadata |> Map.get(:outcome, :unknown) |> to_string()
    }
  end

  defp strategy_tag_values(metadata) do
    %{strategy: metadata |> Map.get(:strategy, :unknown) |> to_string()}
  end

  defp listener_tag_values(metadata) do
    %{listener_id: metadata |> Map.get(:listener_id, :unknown) |> to_string()}
  end

  defp rate_limit_tag_values(metadata) do
    %{
      scope: metadata |> Map.get(:scope, :unknown) |> to_string(),
      traffic_class: metadata |> Map.get(:traffic_class, :generic) |> to_string()
    }
  end

  defp process_tag_values(metadata) do
    process_type = metadata |> Map.get(:process_type, :unknown) |> to_string()
    %{process_type: process_type}
  end

  defp repo_query_tag_values(metadata) do
    %{repo_role: metadata |> Map.get(:repo_role, :unknown) |> to_string()}
  end

  defp status_tag_values(metadata) do
    %{status: metadata |> Map.get(:status, :unknown) |> to_string()}
  end

  defp attach_repo_query_handlers do
    :telemetry.detach(@repo_query_handler_id)

    :telemetry.attach_many(
      @repo_query_handler_id,
      [[:parrhesia, :repo, :query], [:parrhesia, :read_repo, :query]],
      &__MODULE__.handle_repo_query_event/4,
      nil
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def handle_repo_query_event(event_name, measurements, _metadata, _config) do
    repo_role =
      case event_name do
        [:parrhesia, :read_repo, :query] -> :read
        [:parrhesia, :repo, :query] -> :write
      end

    total_time =
      Map.get(
        measurements,
        :total_time,
        Map.get(measurements, :queue_time, 0) +
          Map.get(measurements, :query_time, 0) +
          Map.get(measurements, :decode_time, 0)
      )

    emit(
      [:parrhesia, :db, :query],
      %{
        count: 1,
        total_time: total_time,
        queue_time: Map.get(measurements, :queue_time, 0),
        query_time: Map.get(measurements, :query_time, 0),
        decode_time: Map.get(measurements, :decode_time, 0),
        idle_time: Map.get(measurements, :idle_time, 0)
      },
      %{repo_role: repo_role}
    )
  end
end
