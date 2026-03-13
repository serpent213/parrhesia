defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.Auth.Challenges
  alias Parrhesia.Fanout.MultiNode
  alias Parrhesia.Groups.Flow
  alias Parrhesia.Negentropy.Sessions
  alias Parrhesia.Policy.EventPolicy
  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Storage
  alias Parrhesia.Subscriptions.Index
  alias Parrhesia.Telemetry

  @default_max_subscriptions_per_connection 32
  @default_max_outbound_queue 256
  @default_outbound_drain_batch_size 64
  @default_outbound_overflow_strategy :close
  @drain_outbound_queue :drain_outbound_queue
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
            max_subscriptions_per_connection: @default_max_subscriptions_per_connection,
            subscription_index: Index,
            auth_challenges: Challenges,
            auth_challenge: nil,
            negentropy_sessions: Sessions,
            outbound_queue: :queue.new(),
            outbound_queue_size: 0,
            max_outbound_queue: @default_max_outbound_queue,
            outbound_overflow_strategy: @default_outbound_overflow_strategy,
            outbound_drain_batch_size: @default_outbound_drain_batch_size,
            drain_scheduled?: false

  @type overflow_strategy :: :close | :drop_oldest | :drop_newest

  @type subscription :: %{
          filters: [map()],
          eose_sent?: boolean()
        }

  @type t :: %__MODULE__{
          subscriptions: %{String.t() => subscription()},
          authenticated_pubkeys: MapSet.t(String.t()),
          max_subscriptions_per_connection: pos_integer(),
          subscription_index: GenServer.server() | nil,
          auth_challenges: GenServer.server() | nil,
          auth_challenge: String.t() | nil,
          negentropy_sessions: GenServer.server() | nil,
          outbound_queue: :queue.queue({String.t(), map()}),
          outbound_queue_size: non_neg_integer(),
          max_outbound_queue: pos_integer(),
          outbound_overflow_strategy: overflow_strategy(),
          outbound_drain_batch_size: pos_integer(),
          drain_scheduled?: boolean()
        }

  @impl true
  def init(opts) do
    auth_challenges = auth_challenges(opts)

    state = %__MODULE__{
      max_subscriptions_per_connection: max_subscriptions_per_connection(opts),
      subscription_index: subscription_index(opts),
      auth_challenges: auth_challenges,
      auth_challenge: maybe_issue_auth_challenge(auth_challenges),
      negentropy_sessions: negentropy_sessions(opts),
      max_outbound_queue: max_outbound_queue(opts),
      outbound_overflow_strategy: outbound_overflow_strategy(opts),
      outbound_drain_batch_size: outbound_drain_batch_size(opts)
    }

    {:ok, state}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, %__MODULE__{} = state) do
    case Protocol.decode_client(payload) do
      {:ok, decoded_message} ->
        handle_decoded_message(decoded_message, state)

      {:error, reason} ->
        response = Protocol.encode_relay({:notice, Protocol.decode_error_notice(reason)})
        {:push, {:text, response}, state}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %__MODULE__{} = state) do
    response =
      Protocol.encode_relay({:notice, "invalid: binary websocket frames are not supported"})

    {:push, {:text, response}, state}
  end

  defp handle_decoded_message({:event, event}, state), do: handle_event_ingest(state, event)

  defp handle_decoded_message({:req, subscription_id, filters}, state),
    do: handle_req(state, subscription_id, filters)

  defp handle_decoded_message({:count, subscription_id, filters, options}, state),
    do: handle_count(state, subscription_id, filters, options)

  defp handle_decoded_message({:auth, auth_event}, state), do: handle_auth(state, auth_event)

  defp handle_decoded_message({:neg_open, subscription_id, payload}, state),
    do: handle_neg_open(state, subscription_id, payload)

  defp handle_decoded_message({:neg_msg, subscription_id, payload}, state),
    do: handle_neg_msg(state, subscription_id, payload)

  defp handle_decoded_message({:neg_close, subscription_id}, state),
    do: handle_neg_close(state, subscription_id)

  defp handle_decoded_message({:close, subscription_id}, state) do
    next_state =
      state
      |> drop_subscription(subscription_id)
      |> drop_queued_subscription_events(subscription_id)

    :ok = maybe_remove_index_subscription(next_state, subscription_id)

    response =
      Protocol.encode_relay({:closed, subscription_id, "error: subscription closed"})

    {:push, {:text, response}, next_state}
  end

  @impl true
  def handle_info({:fanout_event, subscription_id, event}, %__MODULE__{} = state)
      when is_binary(subscription_id) and is_map(event) do
    handle_fanout_events(state, [{subscription_id, event}])
  end

  def handle_info({:fanout_events, fanout_events}, %__MODULE__{} = state)
      when is_list(fanout_events) do
    handle_fanout_events(state, fanout_events)
  end

  def handle_info(@drain_outbound_queue, %__MODULE__{} = state) do
    {frames, next_state} = drain_outbound_frames(state)

    if frames == [] do
      {:ok, next_state}
    else
      {:push, frames, next_state}
    end
  end

  def handle_info(_message, %__MODULE__{} = state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    :ok = maybe_remove_index_owner(state)
    :ok = maybe_clear_auth_challenge(state)
    :ok
  end

  defp handle_event_ingest(%__MODULE__{} = state, event) do
    started_at = System.monotonic_time()
    event_id = Map.get(event, "id", "")

    with :ok <- Protocol.validate_event(event),
         :ok <- EventPolicy.authorize_write(event, state.authenticated_pubkeys),
         :ok <- maybe_process_group_event(event),
         {:ok, _result, message} <- persist_event(event) do
      Telemetry.emit(
        [:parrhesia, :ingest, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_event(event)
      )

      fanout_event(event)
      maybe_publish_multi_node(event)

      response = Protocol.encode_relay({:ok, event_id, true, message})
      {:push, {:text, response}, state}
    else
      {:error, reason} ->
        message = error_message_for_ingest_failure(reason)
        response = Protocol.encode_relay({:ok, event_id, false, message})

        if reason in [:auth_required, :protected_event_requires_auth] do
          with_auth_challenge_frame(state, {:push, {:text, response}, state})
        else
          {:push, {:text, response}, state}
        end
    end
  end

  defp handle_req(%__MODULE__{} = state, subscription_id, filters) do
    started_at = System.monotonic_time()

    with :ok <- Filter.validate_filters(filters),
         :ok <- EventPolicy.authorize_read(filters, state.authenticated_pubkeys),
         {:ok, next_state} <- upsert_subscription(state, subscription_id, filters),
         :ok <- maybe_upsert_index_subscription(next_state, subscription_id, filters),
         {:ok, events} <- query_initial_events(filters, state.authenticated_pubkeys) do
      Telemetry.emit(
        [:parrhesia, :query, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_filters(filters)
      )

      frames =
        Enum.map(events, fn event ->
          {:text, Protocol.encode_relay({:event, subscription_id, event})}
        end) ++ [{:text, Protocol.encode_relay({:eose, subscription_id})}]

      {:push, frames, next_state}
    else
      {:error, :auth_required} ->
        restricted_close(state, subscription_id, EventPolicy.error_message(:auth_required))

      {:error, :restricted_giftwrap} ->
        restricted_close(state, subscription_id, EventPolicy.error_message(:restricted_giftwrap))

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
    started_at = System.monotonic_time()

    with :ok <- Filter.validate_filters(filters),
         :ok <- EventPolicy.authorize_read(filters, state.authenticated_pubkeys),
         {:ok, count} <- count_events(filters, state.authenticated_pubkeys),
         {:ok, payload} <- build_count_payload(filters, count, options) do
      Telemetry.emit(
        [:parrhesia, :query, :stop],
        %{duration: System.monotonic_time() - started_at},
        telemetry_metadata_for_filters(filters)
      )

      response = Protocol.encode_relay({:count, subscription_id, payload})
      {:push, {:text, response}, state}
    else
      {:error, :auth_required} ->
        restricted_count_notice(state, subscription_id, EventPolicy.error_message(:auth_required))

      {:error, :restricted_giftwrap} ->
        restricted_count_notice(
          state,
          subscription_id,
          EventPolicy.error_message(:restricted_giftwrap)
        )

      {:error, :marmot_group_h_tag_required} ->
        restricted_count_notice(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_h_tag_required)
        )

      {:error, :marmot_group_h_values_exceeded} ->
        restricted_count_notice(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_h_values_exceeded)
        )

      {:error, :marmot_group_filter_window_too_wide} ->
        restricted_count_notice(
          state,
          subscription_id,
          EventPolicy.error_message(:marmot_group_filter_window_too_wide)
        )

      {:error, reason} ->
        response = Protocol.encode_relay({:closed, subscription_id, inspect(reason)})
        {:push, {:text, response}, state}
    end
  end

  defp handle_auth(%__MODULE__{} = state, auth_event) do
    event_id = Map.get(auth_event, "id", "")

    with :ok <- Protocol.validate_event(auth_event),
         :ok <- validate_auth_event(auth_event),
         :ok <- validate_auth_challenge(state, auth_event) do
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

  defp handle_neg_open(%__MODULE__{} = state, subscription_id, payload) do
    case maybe_open_negentropy(state, subscription_id, payload) do
      {:ok, message} ->
        response = Protocol.encode_relay({:neg_msg, subscription_id, message})
        {:push, {:text, response}, state}

      {:error, reason} ->
        response = Protocol.encode_relay({:closed, subscription_id, "error: #{inspect(reason)}"})
        {:push, {:text, response}, state}
    end
  end

  defp handle_neg_msg(%__MODULE__{} = state, subscription_id, payload) do
    case maybe_negentropy_message(state, subscription_id, payload) do
      {:ok, message} ->
        response = Protocol.encode_relay({:neg_msg, subscription_id, message})
        {:push, {:text, response}, state}

      {:error, reason} ->
        response = Protocol.encode_relay({:closed, subscription_id, "error: #{inspect(reason)}"})
        {:push, {:text, response}, state}
    end
  end

  defp handle_neg_close(%__MODULE__{} = state, subscription_id) do
    :ok = maybe_close_negentropy(state, subscription_id)
    response = Protocol.encode_relay({:neg_msg, subscription_id, %{"status" => "closed"}})
    {:push, {:text, response}, state}
  end

  defp maybe_process_group_event(event) do
    if Flow.group_related_kind?(Map.get(event, "kind")) do
      Flow.handle_event(event)
    else
      :ok
    end
  end

  defp persist_event(event) do
    case Map.get(event, "kind") do
      5 ->
        with {:ok, deleted_count} <- Storage.events().delete_by_request(%{}, event) do
          {:ok, deleted_count, "ok: deletion request processed"}
        end

      62 ->
        with {:ok, deleted_count} <- Storage.events().vanish(%{}, event) do
          {:ok, deleted_count, "ok: vanish request processed"}
        end

      _other ->
        case Storage.events().put_event(%{}, event) do
          {:ok, persisted_event} -> {:ok, persisted_event, "ok: event stored"}
          {:error, :duplicate_event} -> {:error, :duplicate_event}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp error_message_for_ingest_failure(:duplicate_event),
    do: "duplicate: event already stored"

  defp error_message_for_ingest_failure(reason)
       when reason in [
              :auth_required,
              :restricted_giftwrap,
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

  defp query_initial_events(filters, authenticated_pubkeys) do
    Storage.events().query(%{}, filters,
      max_filter_limit: Parrhesia.Config.get([:limits, :max_filter_limit]),
      requester_pubkeys: MapSet.to_list(authenticated_pubkeys)
    )
  end

  defp count_events(filters, authenticated_pubkeys) do
    Storage.events().count(%{}, filters, requester_pubkeys: MapSet.to_list(authenticated_pubkeys))
  end

  defp build_count_payload(filters, count, options) when is_integer(count) and is_map(options) do
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

  defp telemetry_metadata_for_event(event) do
    %{traffic_class: traffic_class_for_event(event)}
  end

  defp telemetry_metadata_for_filters(filters) do
    %{traffic_class: traffic_class_for_filters(filters)}
  end

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

  defp restricted_close(state, subscription_id, reason) do
    response = Protocol.encode_relay({:closed, subscription_id, reason})
    with_auth_challenge_frame(state, {:push, {:text, response}, state})
  end

  defp restricted_count_notice(state, subscription_id, reason) do
    response = Protocol.encode_relay({:closed, subscription_id, reason})
    with_auth_challenge_frame(state, {:push, {:text, response}, state})
  end

  defp validate_auth_event(%{"kind" => 22_242} = auth_event) do
    tags = Map.get(auth_event, "tags", [])

    challenge_tag? =
      Enum.any?(tags, fn
        ["challenge", challenge | _rest] when is_binary(challenge) and challenge != "" -> true
        _tag -> false
      end)

    if challenge_tag?, do: :ok, else: {:error, :missing_challenge_tag}
  end

  defp validate_auth_event(_auth_event), do: {:error, :invalid_auth_kind}

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

  defp auth_error_message(:invalid_auth_kind), do: "invalid: AUTH event kind must be 22242"
  defp auth_error_message(:missing_challenge_tag), do: "invalid: AUTH event missing challenge tag"
  defp auth_error_message(:challenge_mismatch), do: "invalid: AUTH challenge mismatch"
  defp auth_error_message(:missing_challenge), do: "invalid: AUTH challenge unavailable"
  defp auth_error_message(reason) when is_binary(reason), do: reason
  defp auth_error_message(reason), do: "invalid: #{inspect(reason)}"

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

  defp maybe_open_negentropy(%__MODULE__{negentropy_sessions: nil}, _subscription_id, _payload),
    do: {:error, :negentropy_disabled}

  defp maybe_open_negentropy(
         %__MODULE__{negentropy_sessions: negentropy_sessions},
         subscription_id,
         payload
       ) do
    Sessions.open(negentropy_sessions, self(), subscription_id, payload)
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
         payload
       ) do
    Sessions.message(negentropy_sessions, self(), subscription_id, payload)
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

  defp fanout_event(event) do
    case Index.candidate_subscription_keys(event) do
      candidates when is_list(candidates) ->
        Enum.each(candidates, fn {owner_pid, subscription_id} ->
          send(owner_pid, {:fanout_event, subscription_id, event})
        end)

      _other ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp maybe_publish_multi_node(event) do
    MultiNode.publish(event)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp handle_fanout_events(%__MODULE__{} = state, fanout_events) do
    started_at = System.monotonic_time()
    telemetry_metadata = telemetry_metadata_for_fanout_events(fanout_events)

    case enqueue_fanout_events(state, fanout_events) do
      {:ok, next_state} ->
        Telemetry.emit(
          [:parrhesia, :fanout, :stop],
          %{duration: System.monotonic_time() - started_at},
          telemetry_metadata
        )

        {:ok, maybe_schedule_drain(next_state)}

      {:close, next_state} ->
        Telemetry.emit(
          [:parrhesia, :connection, :outbound_queue, :overflow],
          %{count: 1},
          telemetry_metadata
        )

        close_with_outbound_overflow(next_state)
    end
  end

  defp close_with_outbound_overflow(state) do
    message = "rate-limited: outbound queue overflow"
    notice = Protocol.encode_relay({:notice, message})

    {:stop, :normal, {1008, message}, [{:text, notice}], state}
  end

  defp enqueue_fanout_events(state, fanout_events) do
    Enum.reduce_while(fanout_events, {:ok, state}, fn
      {subscription_id, event}, {:ok, acc} when is_binary(subscription_id) and is_map(event) ->
        case maybe_enqueue_fanout_event(acc, subscription_id, event) do
          {:ok, next_acc} -> {:cont, {:ok, next_acc}}
          {:close, next_acc} -> {:halt, {:close, next_acc}}
        end

      _invalid_event, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp maybe_enqueue_fanout_event(state, subscription_id, event) do
    if subscription_matches?(state, subscription_id, event) do
      enqueue_outbound(state, {subscription_id, event}, traffic_class_for_event(event))
    else
      {:ok, state}
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
    {:ok, next_state}
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_newest} = state,
         _queue_entry,
         _traffic_class
       ),
       do: {:ok, state}

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_oldest} = state,
         queue_entry,
         traffic_class
       ) do
    {next_queue, next_size} =
      drop_oldest_and_enqueue(state.outbound_queue, state.outbound_queue_size, queue_entry)

    next_state = %__MODULE__{state | outbound_queue: next_queue, outbound_queue_size: next_size}

    emit_outbound_queue_depth(next_state, %{traffic_class: traffic_class})
    {:ok, next_state}
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

    emit_outbound_queue_depth(next_state)

    {Enum.reverse(frames), next_state}
  end

  defp pop_frames(queue, queue_size, _remaining_batch, acc) when queue_size == 0,
    do: {acc, queue, queue_size}

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

  defp upsert_subscription(%__MODULE__{} = state, subscription_id, filters) do
    subscription = %{filters: filters, eose_sent?: true}

    cond do
      Map.has_key?(state.subscriptions, subscription_id) ->
        {:ok, put_subscription(state, subscription_id, subscription)}

      map_size(state.subscriptions) < state.max_subscriptions_per_connection ->
        {:ok, put_subscription(state, subscription_id, subscription)}

      true ->
        {:error, :subscription_limit_reached}
    end
  end

  defp put_subscription(%__MODULE__{} = state, subscription_id, subscription) do
    subscriptions = Map.put(state.subscriptions, subscription_id, subscription)
    %__MODULE__{state | subscriptions: subscriptions}
  end

  defp drop_subscription(%__MODULE__{} = state, subscription_id) do
    subscriptions = Map.delete(state.subscriptions, subscription_id)
    %__MODULE__{state | subscriptions: subscriptions}
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

  defp maybe_upsert_index_subscription(
         %__MODULE__{subscription_index: nil},
         _subscription_id,
         _filters
       ),
       do: :ok

  defp maybe_upsert_index_subscription(
         %__MODULE__{subscription_index: subscription_index},
         subscription_id,
         filters
       ) do
    case Index.upsert(subscription_index, self(), subscription_id, filters) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  catch
    :exit, _reason -> :ok
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
    |> Keyword.get(:negentropy_sessions, Sessions)
    |> normalize_server_ref()
  end

  defp negentropy_sessions(opts) when is_map(opts) do
    opts
    |> Map.get(:negentropy_sessions, Sessions)
    |> normalize_server_ref()
  end

  defp negentropy_sessions(_opts), do: Sessions

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
end
