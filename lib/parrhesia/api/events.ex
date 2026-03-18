defmodule Parrhesia.API.Events do
  @moduledoc """
  Canonical event publish, query, and count API.
  """

  alias Parrhesia.API.Events.PublishResult
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Fanout.Dispatcher
  alias Parrhesia.Fanout.MultiNode
  alias Parrhesia.NIP43
  alias Parrhesia.Policy.EventPolicy
  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Storage
  alias Parrhesia.Telemetry

  @default_max_event_bytes 262_144

  @marmot_kinds MapSet.new([
                  443,
                  444,
                  445,
                  1059,
                  10_050,
                  10_051,
                  446,
                  447,
                  448,
                  449
                ])

  @spec publish(map(), keyword()) :: {:ok, PublishResult.t()} | {:error, term()}
  def publish(event, opts \\ [])

  def publish(event, opts) when is_map(event) and is_list(opts) do
    started_at = System.monotonic_time()
    event_id = Map.get(event, "id", "")

    with {:ok, context} <- fetch_context(opts),
         :ok <- validate_event_payload_size(event, max_event_bytes(opts)),
         :ok <- Protocol.validate_event(event),
         :ok <- EventPolicy.authorize_write(event, context.authenticated_pubkeys, context),
         {:ok, publish_state} <- NIP43.prepare_publish(event, nip43_opts(opts, context)),
         {:ok, _stored, message} <- persist_event(event) do
      Telemetry.emit(
        [:parrhesia, :ingest, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_event(event)
      )

      message =
        case NIP43.finalize_publish(event, publish_state, nip43_opts(opts, context)) do
          {:ok, override} when is_binary(override) -> override
          :ok -> message
        end

      Dispatcher.dispatch(event)
      maybe_publish_multi_node(event)

      {:ok,
       %PublishResult{
         event_id: event_id,
         accepted: true,
         message: message,
         reason: nil
       }}
    else
      {:error, :invalid_context} = error ->
        error

      {:error, reason} ->
        {:ok,
         %PublishResult{
           event_id: event_id,
           accepted: false,
           message: error_message_for_publish_failure(reason),
           reason: reason
         }}
    end
  end

  def publish(_event, _opts), do: {:error, :invalid_event}

  @spec query([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(filters, opts \\ [])

  def query(filters, opts) when is_list(filters) and is_list(opts) do
    started_at = System.monotonic_time()

    with {:ok, context} <- fetch_context(opts),
         :ok <- maybe_validate_filters(filters, opts),
         :ok <- maybe_authorize_read(filters, context, opts),
         {:ok, events} <- Storage.events().query(%{}, filters, storage_query_opts(context, opts)) do
      events = NIP43.dynamic_events(filters, nip43_opts(opts, context)) ++ events

      Telemetry.emit(
        [:parrhesia, :query, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_filters(filters)
      )

      {:ok, events}
    end
  end

  def query(_filters, _opts), do: {:error, :invalid_filters}

  @spec count([map()], keyword()) :: {:ok, non_neg_integer() | map()} | {:error, term()}
  def count(filters, opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    started_at = System.monotonic_time()

    with {:ok, context} <- fetch_context(opts),
         :ok <- maybe_validate_filters(filters, opts),
         :ok <- maybe_authorize_read(filters, context, opts),
         {:ok, count} <-
           Storage.events().count(%{}, filters, requester_pubkeys: requester_pubkeys(context)),
         count <- count + NIP43.dynamic_count(filters, nip43_opts(opts, context)),
         {:ok, result} <- maybe_build_count_result(filters, count, Keyword.get(opts, :options)) do
      Telemetry.emit(
        [:parrhesia, :query, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_filters(filters)
      )

      {:ok, result}
    end
  end

  def count(_filters, _opts), do: {:error, :invalid_filters}

  defp maybe_validate_filters(filters, opts) do
    if Keyword.get(opts, :validate_filters?, true) do
      Filter.validate_filters(filters)
    else
      :ok
    end
  end

  defp maybe_authorize_read(filters, context, opts) do
    if Keyword.get(opts, :authorize_read?, true) do
      EventPolicy.authorize_read(filters, context.authenticated_pubkeys, context)
    else
      :ok
    end
  end

  defp storage_query_opts(context, opts) do
    [
      max_filter_limit:
        Keyword.get(opts, :max_filter_limit, Parrhesia.Config.get([:limits, :max_filter_limit])),
      requester_pubkeys: requester_pubkeys(context)
    ]
  end

  defp requester_pubkeys(%RequestContext{} = context),
    do: MapSet.to_list(context.authenticated_pubkeys)

  defp maybe_build_count_result(_filters, count, nil) when is_integer(count), do: {:ok, count}

  defp maybe_build_count_result(filters, count, options)
       when is_integer(count) and is_map(options) do
    build_count_payload(filters, count, options)
  end

  defp maybe_build_count_result(_filters, count, _options) when is_integer(count),
    do: {:ok, count}

  defp maybe_build_count_result(_filters, count, _options), do: {:ok, count}

  defp build_count_payload(filters, count, options) do
    include_hll? =
      Map.get(options, "hll", false) and Parrhesia.Config.get([:features, :nip_45_count], true)

    payload = %{"count" => count, "approximate" => false}

    payload =
      if include_hll? do
        Map.put(payload, "hll", generate_hll_payload(filters, count))
      else
        payload
      end

    {:ok, payload}
  end

  defp generate_hll_payload(filters, count) do
    filters
    |> JSON.encode!()
    |> then(&"#{&1}:#{count}")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp persist_event(event) do
    kind = Map.get(event, "kind")

    cond do
      kind in [5, 62] -> persist_control_event(kind, event)
      ephemeral_kind?(kind) -> persist_ephemeral_event()
      true -> persist_regular_event(event)
    end
  end

  defp persist_control_event(5, event) do
    with {:ok, deleted_count} <- Storage.events().delete_by_request(%{}, event) do
      {:ok, deleted_count, "ok: deletion request processed"}
    end
  end

  defp persist_control_event(62, event) do
    with {:ok, deleted_count} <- Storage.events().vanish(%{}, event) do
      {:ok, deleted_count, "ok: vanish request processed"}
    end
  end

  defp persist_ephemeral_event do
    if accept_ephemeral_events?() do
      {:ok, :ephemeral, "ok: ephemeral event accepted"}
    else
      {:error, :ephemeral_events_disabled}
    end
  end

  defp persist_regular_event(event) do
    case Storage.events().put_event(%{}, event) do
      {:ok, persisted_event} -> {:ok, persisted_event, "ok: event stored"}
      {:error, :duplicate_event} -> {:error, :duplicate_event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_publish_multi_node(event) do
    MultiNode.publish(event)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp telemetry_metadata_for_event(event) do
    %{traffic_class: traffic_class_for_event(event)}
  end

  defp telemetry_metadata_for_filters(filters) do
    %{traffic_class: traffic_class_for_filters(filters)}
  end

  defp traffic_class_for_filters(filters) do
    if Enum.any?(filters, &marmot_filter?/1) do
      :marmot
    else
      :generic
    end
  end

  defp marmot_filter?(filter) when is_map(filter) do
    has_marmot_kind? =
      case Map.get(filter, "kinds") do
        kinds when is_list(kinds) -> Enum.any?(kinds, &MapSet.member?(@marmot_kinds, &1))
        _other -> false
      end

    has_marmot_kind? or Map.has_key?(filter, "#h") or Map.has_key?(filter, "#i")
  end

  defp marmot_filter?(_filter), do: false

  defp traffic_class_for_event(event) when is_map(event) do
    if MapSet.member?(@marmot_kinds, Map.get(event, "kind")) do
      :marmot
    else
      :generic
    end
  end

  defp traffic_class_for_event(_event), do: :generic

  defp fetch_context(opts) do
    case Keyword.get(opts, :context) do
      %RequestContext{} = context -> {:ok, context}
      _other -> {:error, :invalid_context}
    end
  end

  defp nip43_opts(opts, %RequestContext{} = context) do
    [context: context, relay_url: Application.get_env(:parrhesia, :relay_url)]
    |> Kernel.++(Keyword.take(opts, [:path, :private_key, :configured_private_key]))
  end

  defp error_message_for_publish_failure(:duplicate_event),
    do: "duplicate: event already stored"

  defp error_message_for_publish_failure(:event_too_large),
    do: "invalid: event exceeds max event size"

  defp error_message_for_publish_failure(:ephemeral_events_disabled),
    do: "blocked: ephemeral events are disabled"

  defp error_message_for_publish_failure(reason)
       when reason in [
              :auth_required,
              :pubkey_not_allowed,
              :restricted_giftwrap,
              :sync_write_not_allowed,
              :protected_event_requires_auth,
              :protected_event_pubkey_mismatch,
              :pow_below_minimum,
              :pubkey_banned,
              :event_banned,
              :media_metadata_tags_exceeded,
              :media_metadata_tag_value_too_large,
              :media_metadata_url_too_long,
              :media_metadata_invalid_url,
              :media_metadata_invalid_hash,
              :media_metadata_invalid_mime,
              :media_metadata_mime_not_allowed,
              :media_metadata_unsupported_version,
              :push_notification_relay_tags_exceeded,
              :push_notification_payload_too_large,
              :push_notification_replay_window_exceeded,
              :push_notification_missing_expiration,
              :push_notification_expiration_too_far,
              :push_notification_server_recipients_exceeded
            ],
       do: EventPolicy.error_message(reason)

  defp error_message_for_publish_failure(reason) when is_binary(reason), do: reason
  defp error_message_for_publish_failure(reason), do: "error: #{inspect(reason)}"

  defp validate_event_payload_size(event, max_event_bytes)
       when is_map(event) and is_integer(max_event_bytes) and max_event_bytes > 0 do
    if byte_size(JSON.encode!(event)) <= max_event_bytes do
      :ok
    else
      {:error, :event_too_large}
    end
  end

  defp validate_event_payload_size(_event, _max_event_bytes), do: :ok

  defp max_event_bytes(opts) do
    opts
    |> Keyword.get(:max_event_bytes, configured_max_event_bytes())
    |> normalize_max_event_bytes()
  end

  defp normalize_max_event_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_event_bytes(_value), do: configured_max_event_bytes()

  defp configured_max_event_bytes do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_event_bytes, @default_max_event_bytes)
  end

  defp ephemeral_kind?(kind) when is_integer(kind), do: kind >= 20_000 and kind < 30_000
  defp ephemeral_kind?(_kind), do: false

  defp accept_ephemeral_events? do
    :parrhesia
    |> Application.get_env(:policies, [])
    |> Keyword.get(:accept_ephemeral_events, true)
  end
end
