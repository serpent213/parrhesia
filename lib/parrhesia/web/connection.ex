defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.API.Events
  alias Parrhesia.API.RequestContext
  alias Parrhesia.API.Stream
  alias Parrhesia.Auth.Challenges
  alias Parrhesia.ConnectionStats
  alias Parrhesia.Negentropy.Sessions
  alias Parrhesia.Policy.ConnectionPolicy
  alias Parrhesia.Policy.EventPolicy
  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Subscriptions.Index
  alias Parrhesia.Telemetry
  alias Parrhesia.Web.EventIngestLimiter
  alias Parrhesia.Web.IPEventIngestLimiter
  alias Parrhesia.Web.Listener

  @default_max_subscriptions_per_connection 32
  @default_max_outbound_queue 256
  @default_outbound_drain_batch_size 64
  @default_outbound_overflow_strategy :close
  @default_max_frame_bytes 1_048_576
  @default_max_event_bytes 262_144
  @default_event_ingest_rate_limit 120
  @default_event_ingest_window_seconds 1
  @default_auth_max_age_seconds 600
  @default_websocket_ping_interval_seconds 30
  @default_websocket_pong_timeout_seconds 10
  @drain_outbound_queue :drain_outbound_queue
  @websocket_keepalive_ping :websocket_keepalive_ping
  @websocket_keepalive_timeout :websocket_keepalive_timeout
  @outbound_queue_pressure_threshold 0.75

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

  defstruct subscriptions: %{},
            authenticated_pubkeys: MapSet.new(),
            listener: nil,
            transport_identity: nil,
            max_subscriptions_per_connection: @default_max_subscriptions_per_connection,
            subscription_index: Index,
            auth_challenges: Challenges,
            auth_challenge: nil,
            relay_url: nil,
            remote_ip: nil,
            negentropy_sessions: Sessions,
            outbound_queue: :queue.new(),
            outbound_queue_size: 0,
            max_outbound_queue: @default_max_outbound_queue,
            outbound_overflow_strategy: @default_outbound_overflow_strategy,
            outbound_drain_batch_size: @default_outbound_drain_batch_size,
            drain_scheduled?: false,
            max_frame_bytes: @default_max_frame_bytes,
            max_event_bytes: @default_max_event_bytes,
            event_ingest_limiter: EventIngestLimiter,
            remote_ip_event_ingest_limiter: IPEventIngestLimiter,
            max_event_ingest_per_window: @default_event_ingest_rate_limit,
            event_ingest_window_seconds: @default_event_ingest_window_seconds,
            event_ingest_window_started_at_ms: 0,
            event_ingest_count: 0,
            auth_max_age_seconds: @default_auth_max_age_seconds,
            websocket_ping_interval_seconds: @default_websocket_ping_interval_seconds,
            websocket_pong_timeout_seconds: @default_websocket_pong_timeout_seconds,
            websocket_keepalive_timeout_timer_ref: nil,
            websocket_awaiting_pong_payload: nil,
            track_population?: true

  @type overflow_strategy :: :close | :drop_oldest | :drop_newest

  @type subscription :: %{
          ref: reference(),
          filters: [map()],
          eose_sent?: boolean()
        }

  @type t :: %__MODULE__{
          subscriptions: %{String.t() => subscription()},
          authenticated_pubkeys: MapSet.t(String.t()),
          listener: map() | nil,
          transport_identity: map() | nil,
          max_subscriptions_per_connection: pos_integer(),
          subscription_index: GenServer.server() | nil,
          auth_challenges: GenServer.server() | nil,
          auth_challenge: String.t() | nil,
          relay_url: String.t() | nil,
          remote_ip: String.t() | nil,
          negentropy_sessions: GenServer.server() | nil,
          outbound_queue: :queue.queue({String.t(), map()}),
          outbound_queue_size: non_neg_integer(),
          max_outbound_queue: pos_integer(),
          outbound_overflow_strategy: overflow_strategy(),
          outbound_drain_batch_size: pos_integer(),
          drain_scheduled?: boolean(),
          max_frame_bytes: pos_integer(),
          max_event_bytes: pos_integer(),
          event_ingest_limiter: GenServer.server() | nil,
          remote_ip_event_ingest_limiter: GenServer.server() | nil,
          max_event_ingest_per_window: pos_integer(),
          event_ingest_window_seconds: pos_integer(),
          event_ingest_window_started_at_ms: integer(),
          event_ingest_count: non_neg_integer(),
          auth_max_age_seconds: pos_integer(),
          websocket_ping_interval_seconds: non_neg_integer(),
          websocket_pong_timeout_seconds: pos_integer(),
          websocket_keepalive_timeout_timer_ref: reference() | nil,
          websocket_awaiting_pong_payload: binary() | nil,
          track_population?: boolean()
        }

  @impl true
  def init(opts) do
    maybe_configure_exit_trapping(opts)
    auth_challenges = auth_challenges(opts)

    state =
      %__MODULE__{
        listener: Listener.from_opts(opts),
        transport_identity: transport_identity(opts),
        max_subscriptions_per_connection: max_subscriptions_per_connection(opts),
        subscription_index: subscription_index(opts),
        auth_challenges: auth_challenges,
        auth_challenge: maybe_issue_auth_challenge(auth_challenges),
        relay_url: relay_url(opts),
        remote_ip: remote_ip(opts),
        negentropy_sessions: negentropy_sessions(opts),
        max_outbound_queue: max_outbound_queue(opts),
        outbound_overflow_strategy: outbound_overflow_strategy(opts),
        outbound_drain_batch_size: outbound_drain_batch_size(opts),
        max_frame_bytes: max_frame_bytes(opts),
        max_event_bytes: max_event_bytes(opts),
        event_ingest_limiter: event_ingest_limiter(opts),
        remote_ip_event_ingest_limiter: remote_ip_event_ingest_limiter(opts),
        max_event_ingest_per_window: max_event_ingest_per_window(opts),
        event_ingest_window_seconds: event_ingest_window_seconds(opts),
        event_ingest_window_started_at_ms: System.monotonic_time(:millisecond),
        auth_max_age_seconds: auth_max_age_seconds(opts),
        websocket_ping_interval_seconds: websocket_ping_interval_seconds(opts),
        websocket_pong_timeout_seconds: websocket_pong_timeout_seconds(opts),
        track_population?: track_population?(opts)
      }
      |> maybe_schedule_next_websocket_ping()

    :ok = maybe_track_connection_open(state)
    Telemetry.emit_process_mailbox_depth(:connection)
    {:ok, state}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, %__MODULE__{} = state) do
    result =
      if byte_size(payload) > state.max_frame_bytes do
        response =
          Protocol.encode_relay({
            :notice,
            "invalid: websocket frame exceeds max frame size"
          })

        {:push, {:text, response}, state}
      else
        case Protocol.decode_client(payload) do
          {:ok, decoded_message} ->
            handle_decoded_message(decoded_message, state)

          {:error, reason} ->
            response = Protocol.encode_relay({:notice, Protocol.decode_error_notice(reason)})
            {:push, {:text, response}, state}
        end
      end

    emit_connection_mailbox_depth(result)
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %__MODULE__{} = state) do
    response =
      Protocol.encode_relay({:notice, "invalid: binary websocket frames are not supported"})

    {:push, {:text, response}, state}
    |> emit_connection_mailbox_depth()
  end

  @impl true
  def handle_control({payload, [opcode: :pong]}, %__MODULE__{} = state) when is_binary(payload) do
    {:ok, maybe_acknowledge_websocket_pong(state, payload)}
    |> emit_connection_mailbox_depth()
  end

  def handle_control({_payload, [opcode: :ping]}, %__MODULE__{} = state) do
    {:ok, state}
    |> emit_connection_mailbox_depth()
  end

  defp handle_decoded_message({:event, event}, state), do: handle_event_ingest(state, event)

  defp handle_decoded_message({:req, subscription_id, filters}, state),
    do: handle_req(state, subscription_id, filters)

  defp handle_decoded_message({:count, subscription_id, filters, options}, state),
    do: handle_count(state, subscription_id, filters, options)

  defp handle_decoded_message({:auth, auth_event}, state), do: handle_auth(state, auth_event)

  defp handle_decoded_message({:neg_open, subscription_id, filter, message}, state),
    do: handle_neg_open(state, subscription_id, filter, message)

  defp handle_decoded_message({:neg_msg, subscription_id, message}, state),
    do: handle_neg_msg(state, subscription_id, message)

  defp handle_decoded_message({:neg_close, subscription_id}, state),
    do: handle_neg_close(state, subscription_id)

  defp handle_decoded_message({:close, subscription_id}, state) do
    next_state =
      state
      |> maybe_unsubscribe_stream_subscription(subscription_id)
      |> drop_subscription(subscription_id)
      |> drop_queued_subscription_events(subscription_id)

    :ok = maybe_remove_index_subscription(next_state, subscription_id)

    response =
      Protocol.encode_relay({:closed, subscription_id, "error: subscription closed"})

    {:push, {:text, response}, next_state}
  end

  @impl true
  def handle_info(
        {:parrhesia, :event, ref, subscription_id, event},
        %__MODULE__{} = state
      )
      when is_reference(ref) and is_binary(subscription_id) and is_map(event) do
    if current_subscription_ref?(state, subscription_id, ref) do
      handle_fanout_events(state, [{subscription_id, event}])
      |> emit_connection_mailbox_depth()
    else
      {:ok, state}
      |> emit_connection_mailbox_depth()
    end
  end

  def handle_info(
        {:parrhesia, :eose, ref, subscription_id},
        %__MODULE__{} = state
      )
      when is_reference(ref) and is_binary(subscription_id) do
    if current_subscription_ref?(state, subscription_id, ref) and
         not subscription_eose_sent?(state, subscription_id) do
      response = Protocol.encode_relay({:eose, subscription_id})

      {:push, {:text, response}, mark_subscription_eose_sent(state, subscription_id)}
      |> emit_connection_mailbox_depth()
    else
      {:ok, state}
      |> emit_connection_mailbox_depth()
    end
  end

  def handle_info(
        {:parrhesia, :closed, ref, subscription_id, reason},
        %__MODULE__{} = state
      )
      when is_reference(ref) and is_binary(subscription_id) do
    if current_subscription_ref?(state, subscription_id, ref) do
      next_state =
        state
        |> drop_subscription(subscription_id)
        |> drop_queued_subscription_events(subscription_id)

      response = Protocol.encode_relay({:closed, subscription_id, stream_closed_reason(reason)})

      {:push, {:text, response}, next_state}
      |> emit_connection_mailbox_depth()
    else
      {:ok, state}
      |> emit_connection_mailbox_depth()
    end
  end

  def handle_info({:fanout_event, subscription_id, event}, %__MODULE__{} = state)
      when is_binary(subscription_id) and is_map(event) do
    handle_fanout_events(state, [{subscription_id, event}])
    |> emit_connection_mailbox_depth()
  end

  def handle_info({:fanout_events, fanout_events}, %__MODULE__{} = state)
      when is_list(fanout_events) do
    handle_fanout_events(state, fanout_events)
    |> emit_connection_mailbox_depth()
  end

  def handle_info(@drain_outbound_queue, %__MODULE__{} = state) do
    {frames, next_state} = drain_outbound_frames(state)

    if frames == [] do
      {:ok, next_state}
      |> emit_connection_mailbox_depth()
    else
      {:push, frames, next_state}
      |> emit_connection_mailbox_depth()
    end
  end

  def handle_info(@websocket_keepalive_ping, %__MODULE__{} = state) do
    state
    |> maybe_schedule_next_websocket_ping()
    |> maybe_send_websocket_keepalive_ping()
    |> emit_connection_mailbox_depth()
  end

  def handle_info({@websocket_keepalive_timeout, payload}, %__MODULE__{} = state)
      when is_binary(payload) do
    if websocket_keepalive_timeout_payload?(state, payload) do
      {:stop, :normal, {1001, "keepalive timeout"}, state}
      |> emit_connection_mailbox_depth()
    else
      {:ok, state}
      |> emit_connection_mailbox_depth()
    end
  end

  def handle_info({:EXIT, _from, :shutdown}, %__MODULE__{} = state) do
    close_with_drained_outbound_frames(state)
    |> emit_connection_mailbox_depth()
  end

  def handle_info({:EXIT, _from, {:shutdown, _detail}}, %__MODULE__{} = state) do
    close_with_drained_outbound_frames(state)
    |> emit_connection_mailbox_depth()
  end

  def handle_info(_message, %__MODULE__{} = state) do
    {:ok, state}
    |> emit_connection_mailbox_depth()
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    :ok = maybe_track_subscription_delta(state, -map_size(state.subscriptions))
    :ok = maybe_track_connection_close(state)
    :ok = maybe_unsubscribe_all_stream_subscriptions(state)
    :ok = maybe_remove_index_owner(state)
    :ok = maybe_clear_auth_challenge(state)
    :ok = cancel_websocket_keepalive_timers(state)
    :ok
  end

  defp handle_event_ingest(%__MODULE__{} = state, event) do
    event_id = Map.get(event, "id", "")
    traffic_class = traffic_class_for_event(event)

    case maybe_allow_event_ingest(state) do
      {:ok, next_state} ->
        maybe_publish_ingested_event(next_state, state, event, event_id)

      {:error, reason} ->
        maybe_emit_rate_limit_hit(reason, traffic_class)
        ingest_error_response(state, event_id, reason)
    end
  end

  defp maybe_publish_ingested_event(next_state, state, event, event_id) do
    traffic_class = traffic_class_for_event(event)

    with :ok <-
           maybe_allow_remote_ip_event_ingest(
             next_state.remote_ip,
             next_state.remote_ip_event_ingest_limiter
           ),
         :ok <- maybe_allow_relay_event_ingest(next_state.event_ingest_limiter),
         :ok <- authorize_listener_write(next_state, event) do
      publish_event_response(next_state, event)
    else
      {:error, reason} ->
        maybe_emit_rate_limit_hit(reason, traffic_class)
        ingest_error_response(state, event_id, reason)
    end
  end

  defp publish_event_response(%__MODULE__{} = state, event) do
    case Events.publish(
           event,
           context: request_context(state),
           max_event_bytes: state.max_event_bytes
         ) do
      {:ok, %{event_id: event_id, accepted: accepted, message: message, reason: reason}} ->
        response = Protocol.encode_relay({:ok, event_id, accepted, message})
        maybe_with_auth_challenge(state, reason, response)

      {:error, reason} ->
        ingest_error_response(state, Map.get(event, "id", ""), reason)
    end
  end

  defp maybe_with_auth_challenge(state, reason, response) do
    if reason in [:auth_required, :protected_event_requires_auth] do
      with_auth_challenge_frame(state, {:push, {:text, response}, state})
    else
      {:push, {:text, response}, state}
    end
  end

  defp ingest_error_response(%__MODULE__{} = state, event_id, reason) do
    message = error_message_for_ingest_failure(reason)
    response = Protocol.encode_relay({:ok, event_id, false, message})

    if reason in [:auth_required, :protected_event_requires_auth] do
      with_auth_challenge_frame(state, {:push, {:text, response}, state})
    else
      {:push, {:text, response}, state}
    end
  end

  defp handle_req(%__MODULE__{} = state, subscription_id, filters) do
    with :ok <- Filter.validate_filters(filters),
         :ok <- authorize_listener_read(state, filters),
         :ok <-
           EventPolicy.authorize_read(
             filters,
             state.authenticated_pubkeys,
             request_context(state, subscription_id)
           ),
         :ok <- ensure_subscription_capacity(state, subscription_id),
         {:ok, ref} <-
           Stream.subscribe(self(), subscription_id, filters,
             context: request_context(state, subscription_id)
           ) do
      next_state =
        state
        |> maybe_unsubscribe_stream_subscription(subscription_id)
        |> put_subscription(subscription_id, %{ref: ref, filters: filters, eose_sent?: false})

      {frames, finalized_state} = drain_initial_stream_frames(next_state, ref, subscription_id)
      {:push, frames, finalized_state}
    else
      {:error, :auth_required} ->
        restricted_close(state, subscription_id, EventPolicy.error_message(:auth_required))

      {:error, :pubkey_not_allowed} ->
        restricted_close(state, subscription_id, EventPolicy.error_message(:pubkey_not_allowed))

      {:error, :restricted_giftwrap} ->
        restricted_close(state, subscription_id, EventPolicy.error_message(:restricted_giftwrap))

      {:error, :sync_read_not_allowed} ->
        restricted_close(
          state,
          subscription_id,
          EventPolicy.error_message(:sync_read_not_allowed)
        )

      {:error, :listener_read_not_allowed} ->
        restricted_close(
          state,
          subscription_id,
          "restricted: listener baseline denies requested filters"
        )

      {:error, :marmot_group_h_tag_required} ->
        restricted_close(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_h_tag_required)
        )

      {:error, :marmot_group_h_values_exceeded} ->
        restricted_close(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_h_values_exceeded)
        )

      {:error, :marmot_group_filter_window_too_wide} ->
        restricted_close(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_filter_window_too_wide)
        )

      {:error, :subscription_limit_reached} ->
        maybe_emit_rate_limit_hit(:subscription_limit_reached)

        response =
          Protocol.encode_relay({
            :closed,
            subscription_id,
            "rate-limited: maximum subscriptions per connection exceeded"
          })

        {:push, {:text, response}, state}

      {:error, reason} ->
        message =
          case reason do
            reason
            when reason in [
                   :invalid_filters,
                   :empty_filters,
                   :too_many_filters,
                   :invalid_filter,
                   :invalid_filter_key,
                   :invalid_ids,
                   :invalid_authors,
                   :invalid_kinds,
                   :invalid_since,
                   :invalid_until,
                   :invalid_limit,
                   :invalid_search,
                   :too_many_tag_values,
                   :invalid_tag_filter
                 ] ->
              Filter.error_message(reason)

            _other ->
              "error: #{inspect(reason)}"
          end

        response = Protocol.encode_relay({:closed, subscription_id, message})
        {:push, {:text, response}, state}
    end
  end

  defp handle_count(%__MODULE__{} = state, subscription_id, filters, options) do
    with :ok <- authorize_listener_read(state, filters),
         {:ok, payload} <-
           Events.count(filters,
             context: request_context(state, subscription_id),
             options: options
           ) do
      response = Protocol.encode_relay({:count, subscription_id, payload})
      {:push, {:text, response}, state}
    else
      {:error, :listener_read_not_allowed} ->
        restricted_count_notice(
          state,
          subscription_id,
          "restricted: listener baseline denies requested filters"
        )

      {:error, reason} ->
        handle_count_error(state, subscription_id, reason)
    end
  end

  defp handle_count_error(state, subscription_id, reason)
       when reason in [
              :auth_required,
              :pubkey_not_allowed,
              :restricted_giftwrap,
              :sync_read_not_allowed,
              :marmot_group_h_tag_required,
              :marmot_group_h_values_exceeded,
              :marmot_group_filter_window_too_wide
            ] do
    restricted_count_notice(state, subscription_id, EventPolicy.error_message(reason))
  end

  defp handle_count_error(state, subscription_id, reason)
       when reason in [
              :invalid_filters,
              :empty_filters,
              :too_many_filters,
              :invalid_filter,
              :invalid_filter_key,
              :invalid_ids,
              :invalid_authors,
              :invalid_kinds,
              :invalid_since,
              :invalid_until,
              :invalid_limit,
              :invalid_search,
              :too_many_tag_values,
              :invalid_tag_filter
            ] do
    response = Protocol.encode_relay({:closed, subscription_id, Filter.error_message(reason)})
    {:push, {:text, response}, state}
  end

  defp handle_count_error(state, subscription_id, reason) do
    response = Protocol.encode_relay({:closed, subscription_id, inspect(reason)})
    {:push, {:text, response}, state}
  end

  defp handle_auth(%__MODULE__{} = state, auth_event) do
    event_id = Map.get(auth_event, "id", "")

    with :ok <- Protocol.validate_event(auth_event),
         :ok <- validate_auth_event(state, auth_event),
         :ok <- validate_auth_challenge(state, auth_event),
         :ok <- authorize_authenticated_pubkey(auth_event) do
      pubkey = Map.get(auth_event, "pubkey")

      next_state =
        %__MODULE__{
          state
          | authenticated_pubkeys: MapSet.put(state.authenticated_pubkeys, pubkey)
        }
        |> rotate_auth_challenge()

      response = Protocol.encode_relay({:ok, event_id, true, "ok: auth accepted"})
      {:push, {:text, response}, next_state}
    else
      {:error, reason} ->
        response = Protocol.encode_relay({:ok, event_id, false, auth_error_message(reason)})
        with_auth_challenge_frame(state, {:push, {:text, response}, state})
    end
  end

  defp handle_neg_open(%__MODULE__{} = state, subscription_id, filter, message) do
    with :ok <- Filter.validate_filters([filter]),
         :ok <- authorize_listener_read(state, [filter]),
         :ok <-
           EventPolicy.authorize_read(
             [filter],
             state.authenticated_pubkeys,
             request_context(state, subscription_id)
           ),
         {:ok, response_message} <-
           maybe_open_negentropy(state, subscription_id, filter, message) do
      response =
        response_message
        |> Base.encode16(case: :lower)
        |> then(&Protocol.encode_relay({:neg_msg, subscription_id, &1}))

      {:push, {:text, response}, state}
    else
      {:error, reason} ->
        negentropy_error_response(state, subscription_id, reason)
    end
  end

  defp handle_neg_msg(%__MODULE__{} = state, subscription_id, message) do
    case maybe_negentropy_message(state, subscription_id, message) do
      {:ok, response_message} ->
        response =
          response_message
          |> Base.encode16(case: :lower)
          |> then(&Protocol.encode_relay({:neg_msg, subscription_id, &1}))

        {:push, {:text, response}, state}

      {:error, reason} ->
        negentropy_error_response(state, subscription_id, reason)
    end
  end

  defp handle_neg_close(%__MODULE__{} = state, subscription_id) do
    :ok = maybe_close_negentropy(state, subscription_id)
    {:ok, state}
  end

  defp error_message_for_ingest_failure(:duplicate_event),
    do: "duplicate: event already stored"

  defp error_message_for_ingest_failure(:event_rate_limited),
    do: "rate-limited: too many EVENT messages"

  defp error_message_for_ingest_failure(:ip_event_rate_limited),
    do: "rate-limited: too many EVENT messages from this IP"

  defp error_message_for_ingest_failure(:relay_event_rate_limited),
    do: "rate-limited: relay-wide EVENT ingress exceeded"

  defp error_message_for_ingest_failure(:event_too_large),
    do: "invalid: event exceeds max event size"

  defp error_message_for_ingest_failure(:listener_write_not_allowed),
    do: "restricted: listener baseline denies event"

  defp error_message_for_ingest_failure(:ephemeral_events_disabled),
    do: "blocked: ephemeral events are disabled"

  defp error_message_for_ingest_failure(reason)
       when reason in [
              :auth_required,
              :pubkey_not_allowed,
              :restricted_giftwrap,
              :sync_write_not_allowed,
              :listener_write_not_allowed,
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

  defp error_message_for_ingest_failure(reason) when is_binary(reason), do: reason
  defp error_message_for_ingest_failure(reason), do: "error: #{inspect(reason)}"

  defp telemetry_metadata_for_fanout_events(fanout_events) do
    traffic_class =
      if Enum.any?(fanout_events, fn
           {_subscription_id, event} when is_map(event) ->
             traffic_class_for_event(event) == :marmot

           _other ->
             false
         end) do
        :marmot
      else
        :generic
      end

    %{traffic_class: traffic_class}
  end

  defp traffic_class_for_event(event) when is_map(event) do
    if MapSet.member?(@marmot_kinds, Map.get(event, "kind")) do
      :marmot
    else
      :generic
    end
  end

  defp traffic_class_for_event(_event), do: :generic

  defp restricted_close(state, subscription_id, reason) do
    response = Protocol.encode_relay({:closed, subscription_id, reason})
    with_auth_challenge_frame(state, {:push, {:text, response}, state})
  end

  defp restricted_count_notice(state, subscription_id, reason) do
    response = Protocol.encode_relay({:closed, subscription_id, reason})
    with_auth_challenge_frame(state, {:push, {:text, response}, state})
  end

  defp negentropy_error_response(state, subscription_id, reason) do
    response =
      Protocol.encode_relay({
        :neg_err,
        subscription_id,
        negentropy_error_message(reason)
      })

    if reason in [:auth_required, :restricted_giftwrap] do
      with_auth_challenge_frame(state, {:push, {:text, response}, state})
    else
      {:push, {:text, response}, state}
    end
  end

  defp negentropy_error_message(reason)
       when reason in [
              :invalid_filters,
              :empty_filters,
              :too_many_filters,
              :invalid_filter,
              :invalid_filter_key,
              :invalid_ids,
              :invalid_authors,
              :invalid_kinds,
              :invalid_since,
              :invalid_until,
              :invalid_limit,
              :invalid_search,
              :too_many_tag_values,
              :invalid_tag_filter,
              :auth_required,
              :pubkey_not_allowed,
              :restricted_giftwrap,
              :sync_read_not_allowed,
              :listener_read_not_allowed,
              :marmot_group_h_tag_required,
              :marmot_group_h_values_exceeded,
              :marmot_group_filter_window_too_wide
            ],
       do: negentropy_policy_or_filter_error_message(reason)

  defp negentropy_error_message(:negentropy_disabled),
    do: "blocked: negentropy is disabled"

  defp negentropy_error_message(:negentropy_unavailable),
    do: "blocked: negentropy is unavailable"

  defp negentropy_error_message(:payload_too_large),
    do: "blocked: negentropy payload exceeds configured limit"

  defp negentropy_error_message(:session_limit_reached),
    do: "blocked: maximum negentropy sessions reached"

  defp negentropy_error_message(:owner_session_limit_reached),
    do: "blocked: maximum negentropy sessions per connection reached"

  defp negentropy_error_message(:query_too_big),
    do: "blocked: negentropy query is too big"

  defp negentropy_error_message(:unknown_session),
    do: "closed: negentropy subscription is not open"

  defp negentropy_error_message(:invalid_message),
    do: "invalid: invalid negentropy message"

  defp negentropy_error_message(reason) when is_binary(reason), do: reason
  defp negentropy_error_message(reason), do: "error: #{inspect(reason)}"

  defp negentropy_policy_or_filter_error_message(reason)
       when reason in [
              :invalid_filters,
              :empty_filters,
              :too_many_filters,
              :invalid_filter,
              :invalid_filter_key,
              :invalid_ids,
              :invalid_authors,
              :invalid_kinds,
              :invalid_since,
              :invalid_until,
              :invalid_limit,
              :invalid_search,
              :too_many_tag_values,
              :invalid_tag_filter
            ],
       do: Filter.error_message(reason)

  defp negentropy_policy_or_filter_error_message(:listener_read_not_allowed),
    do: "restricted: listener baseline denies requested filters"

  defp negentropy_policy_or_filter_error_message(reason), do: EventPolicy.error_message(reason)

  defp validate_auth_event(%__MODULE__{} = state, %{"kind" => 22_242} = auth_event) do
    tags = Map.get(auth_event, "tags", [])

    challenge_tag? =
      Enum.any?(tags, fn
        ["challenge", challenge | _rest] when is_binary(challenge) and challenge != "" -> true
        _tag -> false
      end)

    with :ok <- maybe_validate(challenge_tag?, :missing_challenge_tag),
         :ok <- validate_auth_relay_tag(state, tags) do
      validate_auth_created_at_freshness(auth_event, state.auth_max_age_seconds)
    end
  end

  defp validate_auth_event(_state, _auth_event), do: {:error, :invalid_auth_kind}

  defp validate_auth_challenge(%__MODULE__{auth_challenge: nil}, _auth_event),
    do: {:error, :missing_challenge}

  defp validate_auth_challenge(%__MODULE__{auth_challenge: challenge}, auth_event) do
    challenge_tag_matches? =
      auth_event
      |> Map.get("tags", [])
      |> Enum.any?(fn
        ["challenge", ^challenge | _rest] -> true
        _tag -> false
      end)

    if challenge_tag_matches?, do: :ok, else: {:error, :challenge_mismatch}
  end

  defp validate_auth_relay_tag(%__MODULE__{relay_url: relay_url}, tags)
       when is_binary(relay_url) do
    relay_tag_matches? =
      Enum.any?(tags, fn
        ["relay", ^relay_url | _rest] -> true
        _tag -> false
      end)

    if relay_tag_matches?, do: :ok, else: {:error, :invalid_relay_tag}
  end

  defp validate_auth_relay_tag(%__MODULE__{relay_url: nil}, _tags),
    do: {:error, :missing_relay_configuration}

  defp validate_auth_created_at_freshness(auth_event, max_age_seconds)
       when is_integer(max_age_seconds) and max_age_seconds > 0 do
    created_at = Map.get(auth_event, "created_at", -1)
    now = System.system_time(:second)

    if created_at >= now - max_age_seconds do
      :ok
    else
      {:error, :auth_event_too_old}
    end
  end

  defp validate_auth_created_at_freshness(_auth_event, _max_age_seconds), do: :ok

  defp maybe_validate(true, _reason), do: :ok
  defp maybe_validate(false, reason), do: {:error, reason}

  defp auth_error_message(:invalid_auth_kind), do: "invalid: AUTH event kind must be 22242"
  defp auth_error_message(:missing_challenge_tag), do: "invalid: AUTH event missing challenge tag"
  defp auth_error_message(:invalid_relay_tag), do: "invalid: AUTH relay tag mismatch"

  defp auth_error_message(:missing_relay_configuration),
    do: "invalid: relay URL is not configured"

  defp auth_error_message(:auth_event_too_old), do: "invalid: AUTH event is too old"
  defp auth_error_message(:challenge_mismatch), do: "invalid: AUTH challenge mismatch"
  defp auth_error_message(:missing_challenge), do: "invalid: AUTH challenge unavailable"
  defp auth_error_message(:pubkey_not_allowed), do: EventPolicy.error_message(:pubkey_not_allowed)
  defp auth_error_message(reason) when is_binary(reason), do: reason
  defp auth_error_message(reason), do: "invalid: #{inspect(reason)}"

  defp authorize_listener_read(%__MODULE__{} = state, filters) do
    case maybe_require_listener_auth(state) do
      :ok -> Listener.authorize_read(state.listener, filters)
      error -> error
    end
  end

  defp authorize_listener_write(%__MODULE__{} = state, event) do
    case maybe_require_listener_auth(state) do
      :ok -> Listener.authorize_write(state.listener, event)
      error -> error
    end
  end

  defp maybe_require_listener_auth(%__MODULE__{
         listener: listener,
         authenticated_pubkeys: pubkeys
       }) do
    if Listener.nip42_required?(listener) and MapSet.size(pubkeys) == 0 do
      {:error, :auth_required}
    else
      :ok
    end
  end

  defp with_auth_challenge_frame(
         %__MODULE__{auth_challenge: nil},
         result
       ),
       do: result

  defp with_auth_challenge_frame(%__MODULE__{auth_challenge: challenge}, {:push, frame, state}) do
    auth_frame = {:text, Protocol.encode_relay({:auth, challenge})}
    frames = [auth_frame | List.wrap(frame)]
    {:push, frames, state}
  end

  defp rotate_auth_challenge(%__MODULE__{auth_challenges: nil} = state), do: state

  defp rotate_auth_challenge(%__MODULE__{auth_challenges: auth_challenges} = state) do
    challenge = maybe_issue_auth_challenge(auth_challenges)
    %__MODULE__{state | auth_challenge: challenge}
  end

  defp maybe_issue_auth_challenge(nil), do: nil

  defp maybe_issue_auth_challenge(auth_challenges) do
    Challenges.issue(auth_challenges, self())
  catch
    :exit, _reason -> nil
  end

  defp maybe_clear_auth_challenge(%__MODULE__{auth_challenges: nil}), do: :ok

  defp maybe_clear_auth_challenge(%__MODULE__{auth_challenges: auth_challenges}) do
    :ok = Challenges.clear(auth_challenges, self())
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_open_negentropy(
         %__MODULE__{negentropy_sessions: nil},
         _subscription_id,
         _filter,
         _message
       ),
       do: {:error, :negentropy_disabled}

  defp maybe_open_negentropy(
         %__MODULE__{
           negentropy_sessions: negentropy_sessions,
           authenticated_pubkeys: authenticated_pubkeys
         },
         subscription_id,
         filter,
         message
       ) do
    Sessions.open(
      negentropy_sessions,
      self(),
      subscription_id,
      filter,
      message,
      requester_pubkeys: MapSet.to_list(authenticated_pubkeys)
    )
  catch
    :exit, _reason -> {:error, :negentropy_unavailable}
  end

  defp maybe_negentropy_message(
         %__MODULE__{negentropy_sessions: nil},
         _subscription_id,
         _payload
       ),
       do: {:error, :negentropy_disabled}

  defp maybe_negentropy_message(
         %__MODULE__{negentropy_sessions: negentropy_sessions},
         subscription_id,
         message
       ) do
    Sessions.message(negentropy_sessions, self(), subscription_id, message)
  catch
    :exit, _reason -> {:error, :negentropy_unavailable}
  end

  defp maybe_close_negentropy(%__MODULE__{negentropy_sessions: nil}, _subscription_id), do: :ok

  defp maybe_close_negentropy(
         %__MODULE__{negentropy_sessions: negentropy_sessions},
         subscription_id
       ) do
    Sessions.close(negentropy_sessions, self(), subscription_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp handle_fanout_events(%__MODULE__{} = state, fanout_events) do
    started_at = System.monotonic_time()
    telemetry_metadata = telemetry_metadata_for_fanout_events(fanout_events)

    case enqueue_fanout_events(state, fanout_events) do
      {:ok, next_state, stats} ->
        Telemetry.emit(
          [:parrhesia, :fanout, :stop],
          %{
            duration: System.monotonic_time() - started_at,
            considered: stats.considered,
            enqueued: stats.enqueued
          },
          telemetry_metadata
        )

        {:ok, maybe_schedule_drain(next_state)}

      {:close, next_state, stats} ->
        Telemetry.emit(
          [:parrhesia, :connection, :outbound_queue, :overflow],
          %{count: 1},
          telemetry_metadata
        )

        Telemetry.emit(
          [:parrhesia, :fanout, :stop],
          %{
            duration: System.monotonic_time() - started_at,
            considered: stats.considered,
            enqueued: stats.enqueued
          },
          telemetry_metadata
        )

        maybe_emit_rate_limit_hit(:outbound_queue_overflow, telemetry_metadata.traffic_class)

        close_with_outbound_overflow(next_state)
    end
  end

  defp close_with_outbound_overflow(state) do
    message = "rate-limited: outbound queue overflow"
    notice = Protocol.encode_relay({:notice, message})

    {:stop, :normal, {1008, message}, [{:text, notice}], state}
  end

  defp close_with_drained_outbound_frames(state) do
    {frames, next_state} = drain_all_outbound_frames(state)
    {:stop, :normal, {1012, "service restart"}, frames, next_state}
  end

  defp enqueue_fanout_events(state, fanout_events) do
    initial_stats = %{considered: 0, enqueued: 0}

    Enum.reduce_while(fanout_events, {:ok, state, initial_stats}, fn
      {subscription_id, event}, {:ok, acc, stats}
      when is_binary(subscription_id) and is_map(event) ->
        case maybe_enqueue_fanout_event(acc, subscription_id, event) do
          {:ok, next_acc, enqueued?} ->
            next_stats = %{
              considered: stats.considered + 1,
              enqueued: stats.enqueued + if(enqueued?, do: 1, else: 0)
            }

            {:cont, {:ok, next_acc, next_stats}}

          {:close, next_acc} ->
            next_stats = %{stats | considered: stats.considered + 1}
            {:halt, {:close, next_acc, next_stats}}
        end

      _invalid_event, {:ok, acc, stats} ->
        {:cont, {:ok, acc, stats}}
    end)
  end

  defp maybe_enqueue_fanout_event(state, subscription_id, event) do
    if subscription_matches?(state, subscription_id, event) do
      enqueue_outbound(state, {subscription_id, event}, traffic_class_for_event(event))
    else
      {:ok, state, false}
    end
  end

  defp subscription_matches?(%__MODULE__{} = state, subscription_id, event) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> false
      %{filters: filters} -> Filter.matches_any?(event, filters)
    end
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_queue_size: queue_size, max_outbound_queue: max_outbound_queue} =
           state,
         queue_entry,
         traffic_class
       )
       when queue_size < max_outbound_queue do
    next_state =
      %__MODULE__{
        state
        | outbound_queue: :queue.in(queue_entry, state.outbound_queue),
          outbound_queue_size: queue_size + 1
      }

    emit_outbound_queue_depth(next_state, %{traffic_class: traffic_class})
    {:ok, next_state, true}
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_newest} = state,
         _queue_entry,
         _traffic_class
       ) do
    emit_outbound_queue_drop(:drop_newest)
    {:ok, state, false}
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_oldest} = state,
         queue_entry,
         traffic_class
       ) do
    {next_queue, next_size} =
      drop_oldest_and_enqueue(state.outbound_queue, state.outbound_queue_size, queue_entry)

    next_state = %__MODULE__{state | outbound_queue: next_queue, outbound_queue_size: next_size}

    emit_outbound_queue_depth(next_state, %{traffic_class: traffic_class})
    emit_outbound_queue_drop(:drop_oldest)
    {:ok, next_state, true}
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :close} = state,
         _queue_entry,
         _traffic_class
       ),
       do: {:close, state}

  defp drop_oldest_and_enqueue(queue, queue_size, queue_entry) when queue_size > 0 do
    {_dropped, truncated_queue} = :queue.out(queue)
    {:queue.in(queue_entry, truncated_queue), queue_size}
  end

  defp drop_oldest_and_enqueue(queue, queue_size, queue_entry) do
    {:queue.in(queue_entry, queue), queue_size + 1}
  end

  defp drain_outbound_frames(%__MODULE__{} = state) do
    {frames, next_queue, remaining_size} =
      pop_frames(
        state.outbound_queue,
        state.outbound_queue_size,
        state.outbound_drain_batch_size,
        []
      )

    next_state =
      %__MODULE__{
        state
        | outbound_queue: next_queue,
          outbound_queue_size: remaining_size,
          drain_scheduled?: false
      }
      |> maybe_schedule_drain()

    emit_outbound_queue_drain(length(frames))
    emit_outbound_queue_depth(next_state)

    {Enum.reverse(frames), next_state}
  end

  defp drain_all_outbound_frames(%__MODULE__{} = state) do
    {frames, next_queue, remaining_size} =
      pop_frames(state.outbound_queue, state.outbound_queue_size, :infinity, [])

    next_state =
      %__MODULE__{
        state
        | outbound_queue: next_queue,
          outbound_queue_size: remaining_size,
          drain_scheduled?: false
      }

    emit_outbound_queue_drain(length(frames))
    emit_outbound_queue_depth(next_state)

    {Enum.reverse(frames), next_state}
  end

  defp pop_frames(queue, queue_size, _remaining_batch, acc) when queue_size == 0,
    do: {acc, queue, queue_size}

  defp pop_frames(queue, queue_size, :infinity, acc) do
    case :queue.out(queue) do
      {{:value, {subscription_id, event}}, next_queue} ->
        frame = {:text, Protocol.encode_relay({:event, subscription_id, event})}
        pop_frames(next_queue, queue_size - 1, :infinity, [frame | acc])

      {:empty, _same_queue} ->
        {acc, :queue.new(), 0}
    end
  end

  defp pop_frames(queue, queue_size, remaining_batch, acc) when remaining_batch <= 0,
    do: {acc, queue, queue_size}

  defp pop_frames(queue, queue_size, remaining_batch, acc) do
    case :queue.out(queue) do
      {{:value, {subscription_id, event}}, next_queue} ->
        frame = {:text, Protocol.encode_relay({:event, subscription_id, event})}
        pop_frames(next_queue, queue_size - 1, remaining_batch - 1, [frame | acc])

      {:empty, _same_queue} ->
        {acc, :queue.new(), 0}
    end
  end

  defp maybe_schedule_drain(%__MODULE__{drain_scheduled?: true} = state), do: state

  defp maybe_schedule_drain(%__MODULE__{outbound_queue_size: 0} = state), do: state

  defp maybe_schedule_drain(%__MODULE__{} = state) do
    send(self(), @drain_outbound_queue)
    %__MODULE__{state | drain_scheduled?: true}
  end

  defp maybe_schedule_next_websocket_ping(
         %__MODULE__{websocket_ping_interval_seconds: interval_seconds} = state
       )
       when interval_seconds <= 0,
       do: state

  defp maybe_schedule_next_websocket_ping(
         %__MODULE__{websocket_ping_interval_seconds: interval_seconds} = state
       ) do
    _timer_ref = Process.send_after(self(), @websocket_keepalive_ping, interval_seconds * 1_000)
    state
  end

  defp maybe_send_websocket_keepalive_ping(
         %__MODULE__{websocket_ping_interval_seconds: interval_seconds} = state
       )
       when interval_seconds <= 0,
       do: {:ok, state}

  defp maybe_send_websocket_keepalive_ping(
         %__MODULE__{websocket_awaiting_pong_payload: awaiting_payload} = state
       )
       when is_binary(awaiting_payload),
       do: {:ok, state}

  defp maybe_send_websocket_keepalive_ping(%__MODULE__{} = state) do
    payload = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    timeout_timer_ref =
      Process.send_after(
        self(),
        {@websocket_keepalive_timeout, payload},
        state.websocket_pong_timeout_seconds * 1_000
      )

    next_state =
      %__MODULE__{
        state
        | websocket_keepalive_timeout_timer_ref: timeout_timer_ref,
          websocket_awaiting_pong_payload: payload
      }

    {:push, {:ping, payload}, next_state}
  end

  defp websocket_keepalive_timeout_payload?(
         %__MODULE__{websocket_awaiting_pong_payload: awaiting_payload},
         payload
       )
       when is_binary(awaiting_payload) and is_binary(payload) do
    Plug.Crypto.secure_compare(awaiting_payload, payload)
  end

  defp websocket_keepalive_timeout_payload?(_state, _payload), do: false

  defp maybe_acknowledge_websocket_pong(
         %__MODULE__{websocket_awaiting_pong_payload: awaiting_payload} = state,
         payload
       )
       when is_binary(awaiting_payload) and is_binary(payload) do
    if Plug.Crypto.secure_compare(awaiting_payload, payload) do
      :ok = cancel_timer(state.websocket_keepalive_timeout_timer_ref)

      %__MODULE__{
        state
        | websocket_keepalive_timeout_timer_ref: nil,
          websocket_awaiting_pong_payload: nil
      }
    else
      state
    end
  end

  defp maybe_acknowledge_websocket_pong(%__MODULE__{} = state, _payload), do: state

  defp cancel_websocket_keepalive_timers(%__MODULE__{} = state) do
    :ok = cancel_timer(state.websocket_keepalive_timeout_timer_ref)
    :ok
  end

  defp cancel_timer(timer_ref) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp cancel_timer(_timer_ref), do: :ok

  defp emit_outbound_queue_depth(state, metadata \\ %{}) do
    depth = state.outbound_queue_size

    pressure =
      if state.max_outbound_queue > 0 do
        depth / state.max_outbound_queue
      else
        0.0
      end

    Telemetry.emit(
      [:parrhesia, :connection, :outbound_queue],
      %{depth: depth, pressure: pressure},
      metadata
    )

    if pressure >= @outbound_queue_pressure_threshold do
      Telemetry.emit(
        [:parrhesia, :connection, :outbound_queue, :pressure],
        %{count: 1, pressure: pressure},
        metadata
      )
    end
  end

  defp emit_connection_mailbox_depth(result) do
    Telemetry.emit_process_mailbox_depth(:connection)
    result
  end

  defp ensure_subscription_capacity(%__MODULE__{} = state, subscription_id) do
    cond do
      Map.has_key?(state.subscriptions, subscription_id) ->
        :ok

      map_size(state.subscriptions) < state.max_subscriptions_per_connection ->
        :ok

      true ->
        {:error, :subscription_limit_reached}
    end
  end

  defp put_subscription(%__MODULE__{} = state, subscription_id, subscription) do
    subscriptions = Map.put(state.subscriptions, subscription_id, subscription)
    next_state = %__MODULE__{state | subscriptions: subscriptions}

    if Map.has_key?(state.subscriptions, subscription_id) do
      next_state
    else
      :ok = maybe_track_subscription_delta(next_state, 1)
      next_state
    end
  end

  defp drop_subscription(%__MODULE__{} = state, subscription_id) do
    subscriptions = Map.delete(state.subscriptions, subscription_id)
    next_state = %__MODULE__{state | subscriptions: subscriptions}

    if Map.has_key?(state.subscriptions, subscription_id) do
      :ok = maybe_track_subscription_delta(next_state, -1)
      next_state
    else
      next_state
    end
  end

  defp drop_queued_subscription_events(
         %__MODULE__{outbound_queue_size: 0} = state,
         _subscription_id
       ),
       do: state

  defp drop_queued_subscription_events(%__MODULE__{} = state, subscription_id) do
    filtered_entries =
      state.outbound_queue
      |> :queue.to_list()
      |> Enum.reject(fn
        {^subscription_id, _event} -> true
        _queue_entry -> false
      end)

    next_state =
      %__MODULE__{
        state
        | outbound_queue: :queue.from_list(filtered_entries),
          outbound_queue_size: length(filtered_entries)
      }

    emit_outbound_queue_depth(next_state)

    next_state
  end

  defp maybe_remove_index_subscription(
         %__MODULE__{subscription_index: nil},
         _subscription_id
       ),
       do: :ok

  defp maybe_remove_index_subscription(
         %__MODULE__{subscription_index: subscription_index},
         subscription_id
       ) do
    :ok = Index.remove(subscription_index, self(), subscription_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_remove_index_owner(%__MODULE__{subscription_index: nil}), do: :ok

  defp maybe_remove_index_owner(%__MODULE__{subscription_index: subscription_index}) do
    :ok = Index.remove_owner(subscription_index, self())
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_unsubscribe_stream_subscription(%__MODULE__{} = state, subscription_id) do
    case Map.get(state.subscriptions, subscription_id) do
      %{ref: ref} when is_reference(ref) -> Stream.unsubscribe(ref)
      _other -> :ok
    end

    state
  end

  defp maybe_unsubscribe_all_stream_subscriptions(%__MODULE__{} = state) do
    Enum.each(state.subscriptions, fn {_subscription_id, subscription} ->
      case Map.get(subscription, :ref) do
        ref when is_reference(ref) -> Stream.unsubscribe(ref)
        _other -> :ok
      end
    end)

    :ok
  end

  defp current_subscription_ref?(%__MODULE__{} = state, subscription_id, ref) do
    case Map.get(state.subscriptions, subscription_id) do
      %{ref: ^ref} -> true
      _other -> false
    end
  end

  defp subscription_eose_sent?(%__MODULE__{} = state, subscription_id) do
    case Map.get(state.subscriptions, subscription_id) do
      %{eose_sent?: true} -> true
      _other -> false
    end
  end

  defp mark_subscription_eose_sent(%__MODULE__{} = state, subscription_id) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        state

      subscription ->
        put_subscription(state, subscription_id, Map.put(subscription, :eose_sent?, true))
    end
  end

  defp drain_initial_stream_frames(%__MODULE__{} = state, ref, subscription_id) do
    do_drain_initial_stream_frames(state, ref, subscription_id, [])
  end

  defp do_drain_initial_stream_frames(state, ref, subscription_id, acc) do
    receive do
      {:parrhesia, :event, ^ref, ^subscription_id, event} ->
        frame = {:text, Protocol.encode_relay({:event, subscription_id, event})}
        do_drain_initial_stream_frames(state, ref, subscription_id, [frame | acc])

      {:parrhesia, :eose, ^ref, ^subscription_id} ->
        next_state = mark_subscription_eose_sent(state, subscription_id)
        frame = {:text, Protocol.encode_relay({:eose, subscription_id})}
        {Enum.reverse([frame | acc]), next_state}

      {:parrhesia, :closed, ^ref, ^subscription_id, reason} ->
        next_state = drop_subscription(state, subscription_id)

        frame =
          {:text, Protocol.encode_relay({:closed, subscription_id, stream_closed_reason(reason)})}

        {Enum.reverse([frame | acc]), next_state}
    after
      0 ->
        {Enum.reverse(acc), state}
    end
  end

  defp stream_closed_reason(reason) when is_binary(reason), do: reason
  defp stream_closed_reason(reason), do: inspect(reason)

  defp subscription_index(opts) when is_list(opts) do
    opts
    |> Keyword.get(:subscription_index, Index)
    |> normalize_server_ref()
  end

  defp subscription_index(opts) when is_map(opts) do
    opts
    |> Map.get(:subscription_index, Index)
    |> normalize_server_ref()
  end

  defp subscription_index(_opts), do: Index

  defp auth_challenges(opts) when is_list(opts) do
    opts
    |> Keyword.get(:auth_challenges, Challenges)
    |> normalize_server_ref()
  end

  defp auth_challenges(opts) when is_map(opts) do
    opts
    |> Map.get(:auth_challenges, Challenges)
    |> normalize_server_ref()
  end

  defp auth_challenges(_opts), do: Challenges

  defp negentropy_sessions(opts) when is_list(opts) do
    opts
    |> Keyword.get(:negentropy_sessions, configured_negentropy_sessions())
    |> normalize_server_ref()
  end

  defp negentropy_sessions(opts) when is_map(opts) do
    opts
    |> Map.get(:negentropy_sessions, configured_negentropy_sessions())
    |> normalize_server_ref()
  end

  defp negentropy_sessions(_opts), do: configured_negentropy_sessions()

  defp configured_negentropy_sessions do
    if negentropy_enabled?() do
      Sessions
    else
      nil
    end
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end

  defp normalize_server_ref(server_ref) when is_pid(server_ref) or is_atom(server_ref),
    do: server_ref

  defp normalize_server_ref(_server_ref), do: nil

  defp max_subscriptions_per_connection(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_subscriptions_per_connection)
    |> normalize_max_subscriptions_per_connection()
  end

  defp max_subscriptions_per_connection(opts) when is_map(opts) do
    opts
    |> Map.get(:max_subscriptions_per_connection)
    |> normalize_max_subscriptions_per_connection()
  end

  defp max_subscriptions_per_connection(_opts), do: configured_max_subscriptions_per_connection()

  defp normalize_max_subscriptions_per_connection(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_max_subscriptions_per_connection(_value),
    do: configured_max_subscriptions_per_connection()

  defp configured_max_subscriptions_per_connection do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_subscriptions_per_connection, @default_max_subscriptions_per_connection)
  end

  defp max_outbound_queue(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_outbound_queue)
    |> normalize_max_outbound_queue()
  end

  defp max_outbound_queue(opts) when is_map(opts) do
    opts
    |> Map.get(:max_outbound_queue)
    |> normalize_max_outbound_queue()
  end

  defp max_outbound_queue(_opts), do: configured_max_outbound_queue()

  defp normalize_max_outbound_queue(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_outbound_queue(_value), do: configured_max_outbound_queue()

  defp configured_max_outbound_queue do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_outbound_queue, @default_max_outbound_queue)
  end

  defp outbound_drain_batch_size(opts) when is_list(opts) do
    opts
    |> Keyword.get(:outbound_drain_batch_size)
    |> normalize_outbound_drain_batch_size()
  end

  defp outbound_drain_batch_size(opts) when is_map(opts) do
    opts
    |> Map.get(:outbound_drain_batch_size)
    |> normalize_outbound_drain_batch_size()
  end

  defp outbound_drain_batch_size(_opts), do: configured_outbound_drain_batch_size()

  defp normalize_outbound_drain_batch_size(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_outbound_drain_batch_size(_value), do: configured_outbound_drain_batch_size()

  defp configured_outbound_drain_batch_size do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:outbound_drain_batch_size, @default_outbound_drain_batch_size)
  end

  defp outbound_overflow_strategy(opts) when is_list(opts) do
    opts
    |> Keyword.get(:outbound_overflow_strategy)
    |> normalize_outbound_overflow_strategy()
  end

  defp outbound_overflow_strategy(opts) when is_map(opts) do
    opts
    |> Map.get(:outbound_overflow_strategy)
    |> normalize_outbound_overflow_strategy()
  end

  defp outbound_overflow_strategy(_opts), do: configured_outbound_overflow_strategy()

  defp normalize_outbound_overflow_strategy(:close), do: :close
  defp normalize_outbound_overflow_strategy(:drop_oldest), do: :drop_oldest
  defp normalize_outbound_overflow_strategy(:drop_newest), do: :drop_newest

  defp normalize_outbound_overflow_strategy(_value), do: configured_outbound_overflow_strategy()

  defp configured_outbound_overflow_strategy do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:outbound_overflow_strategy, @default_outbound_overflow_strategy)
  end

  defp relay_url(opts) when is_list(opts) do
    opts
    |> Keyword.get(:relay_url)
    |> normalize_relay_url()
    |> maybe_default_relay_url()
  end

  defp relay_url(opts) when is_map(opts) do
    opts
    |> Map.get(:relay_url)
    |> normalize_relay_url()
    |> maybe_default_relay_url()
  end

  defp relay_url(_opts), do: configured_relay_url()

  defp normalize_relay_url(relay_url) when is_binary(relay_url) and relay_url != "", do: relay_url
  defp normalize_relay_url(_relay_url), do: nil

  defp maybe_default_relay_url(nil), do: configured_relay_url()
  defp maybe_default_relay_url(relay_url), do: relay_url

  defp configured_relay_url do
    :parrhesia
    |> Application.get_env(:relay_url)
    |> normalize_relay_url()
  end

  defp remote_ip(opts) when is_list(opts) do
    opts
    |> Keyword.get(:remote_ip)
    |> normalize_remote_ip()
  end

  defp remote_ip(opts) when is_map(opts) do
    opts
    |> Map.get(:remote_ip)
    |> normalize_remote_ip()
  end

  defp remote_ip(_opts), do: nil

  defp normalize_remote_ip(remote_ip) when is_binary(remote_ip) and remote_ip != "", do: remote_ip
  defp normalize_remote_ip(_remote_ip), do: nil

  defp max_frame_bytes(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_frame_bytes)
    |> normalize_max_frame_bytes()
  end

  defp max_frame_bytes(opts) when is_map(opts) do
    opts
    |> Map.get(:max_frame_bytes)
    |> normalize_max_frame_bytes()
  end

  defp max_frame_bytes(_opts), do: configured_max_frame_bytes()

  defp normalize_max_frame_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_frame_bytes(_value), do: configured_max_frame_bytes()

  defp configured_max_frame_bytes do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_frame_bytes, @default_max_frame_bytes)
  end

  defp max_event_bytes(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_event_bytes)
    |> normalize_max_event_bytes()
  end

  defp max_event_bytes(opts) when is_map(opts) do
    opts
    |> Map.get(:max_event_bytes)
    |> normalize_max_event_bytes()
  end

  defp max_event_bytes(_opts), do: configured_max_event_bytes()

  defp normalize_max_event_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_event_bytes(_value), do: configured_max_event_bytes()

  defp configured_max_event_bytes do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_event_bytes, @default_max_event_bytes)
  end

  defp max_event_ingest_per_window(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_event_ingest_per_window)
    |> normalize_max_event_ingest_per_window()
  end

  defp max_event_ingest_per_window(opts) when is_map(opts) do
    opts
    |> Map.get(:max_event_ingest_per_window)
    |> normalize_max_event_ingest_per_window()
  end

  defp max_event_ingest_per_window(_opts), do: configured_max_event_ingest_per_window()

  defp normalize_max_event_ingest_per_window(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_max_event_ingest_per_window(_value),
    do: configured_max_event_ingest_per_window()

  defp configured_max_event_ingest_per_window do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_event_ingest_per_window, @default_event_ingest_rate_limit)
  end

  defp event_ingest_limiter(opts) when is_list(opts) do
    Keyword.get(opts, :event_ingest_limiter, EventIngestLimiter)
  end

  defp event_ingest_limiter(opts) when is_map(opts) do
    Map.get(opts, :event_ingest_limiter, EventIngestLimiter)
  end

  defp event_ingest_limiter(_opts), do: EventIngestLimiter

  defp remote_ip_event_ingest_limiter(opts) when is_list(opts) do
    Keyword.get(opts, :remote_ip_event_ingest_limiter, IPEventIngestLimiter)
  end

  defp remote_ip_event_ingest_limiter(opts) when is_map(opts) do
    Map.get(opts, :remote_ip_event_ingest_limiter, IPEventIngestLimiter)
  end

  defp remote_ip_event_ingest_limiter(_opts), do: IPEventIngestLimiter

  defp event_ingest_window_seconds(opts) when is_list(opts) do
    opts
    |> Keyword.get(:event_ingest_window_seconds)
    |> normalize_event_ingest_window_seconds()
  end

  defp event_ingest_window_seconds(opts) when is_map(opts) do
    opts
    |> Map.get(:event_ingest_window_seconds)
    |> normalize_event_ingest_window_seconds()
  end

  defp event_ingest_window_seconds(_opts), do: configured_event_ingest_window_seconds()

  defp normalize_event_ingest_window_seconds(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_event_ingest_window_seconds(_value), do: configured_event_ingest_window_seconds()

  defp configured_event_ingest_window_seconds do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:event_ingest_window_seconds, @default_event_ingest_window_seconds)
  end

  defp auth_max_age_seconds(opts) when is_list(opts) do
    opts
    |> Keyword.get(:auth_max_age_seconds)
    |> normalize_auth_max_age_seconds()
  end

  defp auth_max_age_seconds(opts) when is_map(opts) do
    opts
    |> Map.get(:auth_max_age_seconds)
    |> normalize_auth_max_age_seconds()
  end

  defp auth_max_age_seconds(_opts), do: configured_auth_max_age_seconds()

  defp normalize_auth_max_age_seconds(value) when is_integer(value) and value > 0, do: value
  defp normalize_auth_max_age_seconds(_value), do: configured_auth_max_age_seconds()

  defp configured_auth_max_age_seconds do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:auth_max_age_seconds, @default_auth_max_age_seconds)
  end

  defp websocket_ping_interval_seconds(opts) when is_list(opts) do
    opts
    |> Keyword.get(:websocket_ping_interval_seconds)
    |> normalize_websocket_ping_interval_seconds()
  end

  defp websocket_ping_interval_seconds(opts) when is_map(opts) do
    opts
    |> Map.get(:websocket_ping_interval_seconds)
    |> normalize_websocket_ping_interval_seconds()
  end

  defp websocket_ping_interval_seconds(_opts), do: configured_websocket_ping_interval_seconds()

  defp normalize_websocket_ping_interval_seconds(value)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_websocket_ping_interval_seconds(_value),
    do: configured_websocket_ping_interval_seconds()

  defp configured_websocket_ping_interval_seconds do
    case Application.get_env(:parrhesia, :limits, [])
         |> Keyword.get(:websocket_ping_interval_seconds) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @default_websocket_ping_interval_seconds
    end
  end

  defp websocket_pong_timeout_seconds(opts) when is_list(opts) do
    opts
    |> Keyword.get(:websocket_pong_timeout_seconds)
    |> normalize_websocket_pong_timeout_seconds()
  end

  defp websocket_pong_timeout_seconds(opts) when is_map(opts) do
    opts
    |> Map.get(:websocket_pong_timeout_seconds)
    |> normalize_websocket_pong_timeout_seconds()
  end

  defp websocket_pong_timeout_seconds(_opts), do: configured_websocket_pong_timeout_seconds()

  defp normalize_websocket_pong_timeout_seconds(value)
       when is_integer(value) and value > 0,
       do: value

  defp normalize_websocket_pong_timeout_seconds(_value),
    do: configured_websocket_pong_timeout_seconds()

  defp configured_websocket_pong_timeout_seconds do
    case Application.get_env(:parrhesia, :limits, [])
         |> Keyword.get(:websocket_pong_timeout_seconds) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_websocket_pong_timeout_seconds
    end
  end

  defp track_population?(opts) when is_list(opts), do: Keyword.get(opts, :track_population?, true)
  defp track_population?(opts) when is_map(opts), do: Map.get(opts, :track_population?, true)
  defp track_population?(_opts), do: true

  defp maybe_configure_exit_trapping(opts) do
    if trap_exit?(opts) do
      Process.flag(:trap_exit, true)
    end

    :ok
  end

  defp trap_exit?(opts) when is_list(opts), do: Keyword.get(opts, :trap_exit?, true)
  defp trap_exit?(opts) when is_map(opts), do: Map.get(opts, :trap_exit?, true)
  defp trap_exit?(_opts), do: true

  defp request_context(%__MODULE__{} = state, subscription_id \\ nil) do
    %RequestContext{
      authenticated_pubkeys: state.authenticated_pubkeys,
      caller: :websocket,
      remote_ip: state.remote_ip,
      subscription_id: subscription_id,
      transport_identity: state.transport_identity,
      metadata: %{
        listener_id: state.listener.id,
        transport_identity: state.transport_identity
      }
    }
  end

  defp transport_identity(opts) when is_list(opts), do: Keyword.get(opts, :transport_identity)
  defp transport_identity(opts) when is_map(opts), do: Map.get(opts, :transport_identity)
  defp transport_identity(_opts), do: nil

  defp authorize_authenticated_pubkey(%{"pubkey" => pubkey}) when is_binary(pubkey) do
    ConnectionPolicy.authorize_authenticated_pubkey(pubkey)
  end

  defp authorize_authenticated_pubkey(_auth_event), do: {:error, :invalid_event}

  defp maybe_allow_event_ingest(
         %__MODULE__{
           event_ingest_window_started_at_ms: window_started_at_ms,
           event_ingest_window_seconds: window_seconds,
           event_ingest_count: count,
           max_event_ingest_per_window: max_event_ingest_per_window
         } = state
       ) do
    now_ms = System.monotonic_time(:millisecond)
    window_ms = window_seconds * 1000

    cond do
      now_ms - window_started_at_ms >= window_ms ->
        {:ok,
         %__MODULE__{
           state
           | event_ingest_window_started_at_ms: now_ms,
             event_ingest_count: 1
         }}

      count < max_event_ingest_per_window ->
        {:ok, %__MODULE__{state | event_ingest_count: count + 1}}

      true ->
        {:error, :event_rate_limited}
    end
  end

  defp maybe_allow_remote_ip_event_ingest(_remote_ip, nil), do: :ok

  defp maybe_allow_remote_ip_event_ingest(remote_ip, server) do
    IPEventIngestLimiter.allow(remote_ip, server)
  catch
    :exit, {:noproc, _details} -> :ok
    :exit, {:normal, _details} -> :ok
  end

  defp maybe_allow_relay_event_ingest(nil), do: :ok

  defp maybe_allow_relay_event_ingest(server) do
    EventIngestLimiter.allow(server)
  catch
    :exit, {:noproc, _details} -> :ok
    :exit, {:normal, _details} -> :ok
  end

  defp maybe_track_connection_open(%__MODULE__{track_population?: false}), do: :ok

  defp maybe_track_connection_open(%__MODULE__{} = state) do
    ConnectionStats.connection_open(listener_id(state))
  end

  defp maybe_track_connection_close(%__MODULE__{track_population?: false}), do: :ok

  defp maybe_track_connection_close(%__MODULE__{} = state) do
    ConnectionStats.connection_close(listener_id(state))
  end

  defp maybe_track_subscription_delta(_state, 0), do: :ok
  defp maybe_track_subscription_delta(%__MODULE__{track_population?: false}, _delta), do: :ok

  defp maybe_track_subscription_delta(%__MODULE__{} = state, delta) do
    ConnectionStats.subscriptions_change(listener_id(state), delta)
  end

  defp listener_id(%__MODULE__{listener: %{id: id}}), do: id
  defp listener_id(_state), do: :unknown

  defp emit_outbound_queue_drain(0), do: :ok

  defp emit_outbound_queue_drain(count) when is_integer(count) and count > 0 do
    Telemetry.emit([:parrhesia, :connection, :outbound_queue, :drain], %{count: count}, %{})
  end

  defp emit_outbound_queue_drop(strategy) do
    Telemetry.emit(
      [:parrhesia, :connection, :outbound_queue, :drop],
      %{count: 1},
      %{strategy: strategy}
    )
  end

  defp maybe_emit_rate_limit_hit(reason, traffic_class \\ :generic)

  defp maybe_emit_rate_limit_hit(:event_rate_limited, traffic_class) do
    emit_rate_limit_hit(:event_ingest_per_connection, traffic_class)
  end

  defp maybe_emit_rate_limit_hit(:ip_event_rate_limited, traffic_class) do
    emit_rate_limit_hit(:event_ingest_per_ip, traffic_class)
  end

  defp maybe_emit_rate_limit_hit(:relay_event_rate_limited, traffic_class) do
    emit_rate_limit_hit(:event_ingest_relay, traffic_class)
  end

  defp maybe_emit_rate_limit_hit(:subscription_limit_reached, traffic_class) do
    emit_rate_limit_hit(:subscriptions_per_connection, traffic_class)
  end

  defp maybe_emit_rate_limit_hit(:outbound_queue_overflow, traffic_class) do
    emit_rate_limit_hit(:outbound_queue, traffic_class)
  end

  defp maybe_emit_rate_limit_hit(_reason, _traffic_class), do: :ok

  defp emit_rate_limit_hit(scope, traffic_class) do
    Telemetry.emit(
      [:parrhesia, :rate_limit, :hit],
      %{count: 1},
      %{scope: scope, traffic_class: traffic_class}
    )
  end
end
