defmodule Parrhesia.Storage.Adapters.Postgres.Events do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Events`.
  """

  import Ecto.Query

  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Events

  @type normalized_event :: %{
          id: binary(),
          pubkey: binary(),
          created_at: non_neg_integer(),
          kind: non_neg_integer(),
          content: String.t(),
          sig: binary(),
          d_tag: String.t(),
          expires_at: non_neg_integer() | nil,
          tags: [list(String.t())]
        }

  @impl true
  def put_event(_context, event) do
    with {:ok, normalized} <- normalize_event(event) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        insert_event_id!(normalized, now)
        insert_event!(normalized, now)
        insert_tags!(normalized, now)
        upsert_state_tables!(normalized, now)

        event
      end)
      |> case do
        {:ok, persisted_event} -> {:ok, persisted_event}
        {:error, :duplicate_event} -> {:error, :duplicate_event}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def get_event(_context, event_id) do
    with {:ok, decoded_event_id} <- decode_hex(event_id, 32, :invalid_event_id) do
      event_query =
        from(event in "events",
          where: event.id == ^decoded_event_id and is_nil(event.deleted_at),
          order_by: [desc: event.created_at],
          limit: 1,
          select: %{
            id: event.id,
            pubkey: event.pubkey,
            created_at: event.created_at,
            kind: event.kind,
            content: event.content,
            sig: event.sig
          }
        )

      case Repo.one(event_query) do
        nil ->
          {:ok, nil}

        persisted_event ->
          tags = load_tags([{persisted_event.created_at, persisted_event.id}])

          {:ok,
           to_nostr_event(
             persisted_event,
             Map.get(tags, {persisted_event.created_at, persisted_event.id}, [])
           )}
      end
    end
  end

  @impl true
  def query(_context, filters, opts) when is_list(opts) do
    with :ok <- Filter.validate_filters(filters) do
      now = Keyword.get(opts, :now, System.system_time(:second))

      persisted_events =
        filters
        |> Enum.flat_map(fn filter ->
          filter
          |> event_query_for_filter(now, opts)
          |> Repo.all()
        end)
        |> deduplicate_events()
        |> sort_persisted_events()
        |> maybe_apply_query_limit(opts)

      event_keys = Enum.map(persisted_events, fn event -> {event.created_at, event.id} end)
      tags_by_event = load_tags(event_keys)

      nostr_events =
        Enum.map(persisted_events, fn event ->
          to_nostr_event(event, Map.get(tags_by_event, {event.created_at, event.id}, []))
        end)

      {:ok, nostr_events}
    end
  end

  def query(_context, _filters, _opts), do: {:error, :invalid_opts}

  @impl true
  def count(_context, filters, opts) when is_list(opts) do
    with :ok <- Filter.validate_filters(filters) do
      now = Keyword.get(opts, :now, System.system_time(:second))

      total_count =
        filters
        |> Enum.flat_map(fn filter ->
          filter
          |> event_id_query_for_filter(now)
          |> Repo.all()
        end)
        |> MapSet.new()
        |> MapSet.size()

      {:ok, total_count}
    end
  end

  def count(_context, _filters, _opts), do: {:error, :invalid_opts}

  @impl true
  def delete_by_request(_context, _event), do: {:error, :not_implemented}

  @impl true
  def vanish(_context, _event), do: {:error, :not_implemented}

  @impl true
  def purge_expired(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    query =
      from(event in "events",
        where: not is_nil(event.expires_at) and event.expires_at <= ^now
      )

    {count, _result} = Repo.delete_all(query)
    {:ok, count}
  end

  @doc false
  @spec normalize_event(map()) :: {:ok, normalized_event()} | {:error, atom()}
  def normalize_event(event) when is_map(event) do
    with {:ok, id} <- decode_hex(Map.get(event, "id"), 32, :invalid_event_id),
         {:ok, pubkey} <- decode_hex(Map.get(event, "pubkey"), 32, :invalid_pubkey),
         {:ok, sig} <- decode_hex(Map.get(event, "sig"), 64, :invalid_sig),
         {:ok, created_at} <-
           validate_non_negative_integer(Map.get(event, "created_at"), :invalid_created_at),
         {:ok, kind} <- validate_non_negative_integer(Map.get(event, "kind"), :invalid_kind),
         {:ok, content} <- validate_binary(Map.get(event, "content"), :invalid_content),
         {:ok, tags} <- validate_tags(Map.get(event, "tags")) do
      {:ok,
       %{
         id: id,
         pubkey: pubkey,
         created_at: created_at,
         kind: kind,
         content: content,
         sig: sig,
         d_tag: extract_d_tag(tags),
         expires_at: extract_expiration(tags),
         tags: tags
       }}
    end
  end

  def normalize_event(_event), do: {:error, :invalid_event}

  @doc false
  @spec candidate_wins_state?(normalized_event(), map()) :: boolean()
  def candidate_wins_state?(candidate, current) do
    cond do
      candidate.created_at > current.event_created_at -> true
      candidate.created_at < current.event_created_at -> false
      true -> candidate.id < current.event_id
    end
  end

  defp insert_event_id!(normalized_event, now) do
    {inserted, _result} =
      Repo.insert_all(
        "event_ids",
        [
          %{
            id: normalized_event.id,
            created_at: normalized_event.created_at,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:id]
      )

    if inserted == 1 do
      :ok
    else
      Repo.rollback(:duplicate_event)
    end
  end

  defp insert_event!(normalized_event, now) do
    {inserted, _result} =
      Repo.insert_all("events", [event_row(normalized_event, now)])

    if inserted == 1 do
      :ok
    else
      Repo.rollback(:event_insert_failed)
    end
  end

  defp insert_tags!(normalized_event, now) do
    tag_rows =
      normalized_event.tags
      |> Enum.with_index()
      |> Enum.flat_map(fn {tag, idx} ->
        case tag do
          [name, value | _rest] when is_binary(name) and is_binary(value) ->
            [
              %{
                event_created_at: normalized_event.created_at,
                event_id: normalized_event.id,
                name: name,
                value: value,
                idx: idx,
                inserted_at: now
              }
            ]

          _other ->
            []
        end
      end)

    if tag_rows == [] do
      :ok
    else
      {inserted, _result} = Repo.insert_all("event_tags", tag_rows)

      if inserted == length(tag_rows) do
        :ok
      else
        Repo.rollback(:tag_insert_failed)
      end
    end
  end

  defp upsert_state_tables!(normalized_event, now) do
    :ok = maybe_upsert_replaceable_state(normalized_event, now)
    :ok = maybe_upsert_addressable_state(normalized_event, now)
    :ok
  end

  defp maybe_upsert_replaceable_state(normalized_event, now) do
    if replaceable_kind?(normalized_event.kind) do
      lookup_query =
        from(state in "replaceable_event_state",
          where:
            state.pubkey == ^normalized_event.pubkey and state.kind == ^normalized_event.kind,
          select: %{event_created_at: state.event_created_at, event_id: state.event_id}
        )

      update_query =
        from(state in "replaceable_event_state",
          where:
            state.pubkey == ^normalized_event.pubkey and
              state.kind == ^normalized_event.kind
        )

      upsert_state_table(
        "replaceable_event_state",
        lookup_query,
        update_query,
        replaceable_state_row(normalized_event, now),
        normalized_event,
        now,
        :replaceable_state_update_failed
      )
    else
      :ok
    end
  end

  defp maybe_upsert_addressable_state(normalized_event, now) do
    if addressable_kind?(normalized_event.kind) do
      lookup_query =
        from(state in "addressable_event_state",
          where:
            state.pubkey == ^normalized_event.pubkey and
              state.kind == ^normalized_event.kind and
              state.d_tag == ^normalized_event.d_tag,
          select: %{event_created_at: state.event_created_at, event_id: state.event_id}
        )

      update_query =
        from(state in "addressable_event_state",
          where:
            state.pubkey == ^normalized_event.pubkey and
              state.kind == ^normalized_event.kind and
              state.d_tag == ^normalized_event.d_tag
        )

      upsert_state_table(
        "addressable_event_state",
        lookup_query,
        update_query,
        addressable_state_row(normalized_event, now),
        normalized_event,
        now,
        :addressable_state_update_failed
      )
    else
      :ok
    end
  end

  defp upsert_state_table(
         table_name,
         lookup_query,
         update_query,
         insert_row,
         normalized_event,
         now,
         failure_reason
       ) do
    case Repo.one(lookup_query) do
      nil ->
        {inserted, _result} = Repo.insert_all(table_name, [insert_row], on_conflict: :nothing)

        if inserted <= 1 do
          :ok
        else
          Repo.rollback(failure_reason)
        end

      current_state ->
        maybe_update_state(update_query, normalized_event, current_state, now, failure_reason)
    end
  end

  defp maybe_update_state(update_query, normalized_event, current_state, now, failure_reason) do
    if candidate_wins_state?(normalized_event, current_state) do
      {updated, _result} =
        Repo.update_all(update_query,
          set: [
            event_created_at: normalized_event.created_at,
            event_id: normalized_event.id,
            updated_at: now
          ]
        )

      if updated == 1 do
        :ok
      else
        Repo.rollback(failure_reason)
      end
    else
      :ok
    end
  end

  defp replaceable_kind?(kind), do: kind in [0, 3] or (kind >= 10_000 and kind < 20_000)

  defp addressable_kind?(kind), do: kind >= 30_000 and kind < 40_000

  defp replaceable_state_row(normalized_event, now) do
    %{
      pubkey: normalized_event.pubkey,
      kind: normalized_event.kind,
      event_created_at: normalized_event.created_at,
      event_id: normalized_event.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp addressable_state_row(normalized_event, now) do
    %{
      pubkey: normalized_event.pubkey,
      kind: normalized_event.kind,
      d_tag: normalized_event.d_tag,
      event_created_at: normalized_event.created_at,
      event_id: normalized_event.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp event_row(normalized_event, now) do
    %{
      id: normalized_event.id,
      pubkey: normalized_event.pubkey,
      created_at: normalized_event.created_at,
      kind: normalized_event.kind,
      content: normalized_event.content,
      sig: normalized_event.sig,
      d_tag: normalized_event.d_tag,
      expires_at: normalized_event.expires_at,
      inserted_at: now,
      updated_at: now
    }
  end

  defp event_query_for_filter(filter, now, opts) do
    base_query =
      from(event in "events",
        where: is_nil(event.deleted_at) and (is_nil(event.expires_at) or event.expires_at > ^now),
        order_by: [desc: event.created_at, asc: event.id],
        select: %{
          id: event.id,
          pubkey: event.pubkey,
          created_at: event.created_at,
          kind: event.kind,
          content: event.content,
          sig: event.sig
        }
      )

    query =
      base_query
      |> maybe_filter_ids(Map.get(filter, "ids"))
      |> maybe_filter_authors(Map.get(filter, "authors"))
      |> maybe_filter_kinds(Map.get(filter, "kinds"))
      |> maybe_filter_since(Map.get(filter, "since"))
      |> maybe_filter_until(Map.get(filter, "until"))
      |> filter_by_tags(filter)

    maybe_limit_query(query, effective_filter_limit(filter, opts))
  end

  defp event_id_query_for_filter(filter, now) do
    from(event in "events",
      where: is_nil(event.deleted_at) and (is_nil(event.expires_at) or event.expires_at > ^now),
      select: event.id
    )
    |> maybe_filter_ids(Map.get(filter, "ids"))
    |> maybe_filter_authors(Map.get(filter, "authors"))
    |> maybe_filter_kinds(Map.get(filter, "kinds"))
    |> maybe_filter_since(Map.get(filter, "since"))
    |> maybe_filter_until(Map.get(filter, "until"))
    |> filter_by_tags(filter)
  end

  defp maybe_filter_ids(query, nil), do: query

  defp maybe_filter_ids(query, ids) do
    decoded_ids = decode_hex_list(ids, :lower)
    where(query, [event], event.id in ^decoded_ids)
  end

  defp maybe_filter_authors(query, nil), do: query

  defp maybe_filter_authors(query, authors) do
    decoded_authors = decode_hex_list(authors, :lower)
    where(query, [event], event.pubkey in ^decoded_authors)
  end

  defp maybe_filter_kinds(query, nil), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [event], event.kind in ^kinds)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [event], event.created_at >= ^since)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [event], event.created_at <= ^until)

  defp filter_by_tags(query, filter) do
    filter
    |> tag_filters()
    |> Enum.reduce(query, fn {tag_name, values}, acc ->
      where(
        acc,
        [event],
        fragment(
          "EXISTS (SELECT 1 FROM event_tags AS tag WHERE tag.event_created_at = ? AND tag.event_id = ? AND tag.name = ? AND tag.value = ANY(?))",
          event.created_at,
          event.id,
          ^tag_name,
          type(^values, {:array, :string})
        )
      )
    end)
  end

  defp tag_filters(filter) do
    Enum.reduce(filter, [], fn
      {<<"#", tag_name::binary-size(1)>>, values}, acc -> [{tag_name, values} | acc]
      _entry, acc -> acc
    end)
  end

  defp decode_hex_list(values, decode_case) when is_list(values) do
    Enum.map(values, &Base.decode16!(&1, case: decode_case))
  end

  defp effective_filter_limit(filter, opts) do
    filter_limit = Map.get(filter, "limit")
    max_filter_limit = Keyword.get(opts, :max_filter_limit)

    cond do
      is_integer(filter_limit) and is_integer(max_filter_limit) ->
        min(filter_limit, max_filter_limit)

      is_integer(filter_limit) ->
        filter_limit

      is_integer(max_filter_limit) ->
        max_filter_limit

      true ->
        nil
    end
  end

  defp maybe_limit_query(query, nil), do: query
  defp maybe_limit_query(query, limit), do: limit(query, ^limit)

  defp deduplicate_events(events) do
    events
    |> Enum.reduce(%{}, fn event, acc -> Map.put_new(acc, event.id, event) end)
    |> Map.values()
  end

  defp sort_persisted_events(events) do
    Enum.sort(events, fn left, right ->
      cond do
        left.created_at > right.created_at -> true
        left.created_at < right.created_at -> false
        true -> left.id < right.id
      end
    end)
  end

  defp maybe_apply_query_limit(events, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(events, limit)
      _other -> events
    end
  end

  defp load_tags([]), do: %{}

  defp load_tags(event_keys) when is_list(event_keys) do
    created_at_values = Enum.map(event_keys, fn {created_at, _event_id} -> created_at end)
    event_id_values = Enum.map(event_keys, fn {_created_at, event_id} -> event_id end)

    query =
      from(tag in "event_tags",
        where: tag.event_created_at in ^created_at_values and tag.event_id in ^event_id_values,
        order_by: [asc: tag.idx],
        select: %{
          event_created_at: tag.event_created_at,
          event_id: tag.event_id,
          name: tag.name,
          value: tag.value
        }
      )

    query
    |> Repo.all()
    |> Enum.group_by(
      fn tag -> {tag.event_created_at, tag.event_id} end,
      fn tag -> [tag.name, tag.value] end
    )
  end

  defp to_nostr_event(persisted_event, tags) do
    %{
      "id" => Base.encode16(persisted_event.id, case: :lower),
      "pubkey" => Base.encode16(persisted_event.pubkey, case: :lower),
      "created_at" => persisted_event.created_at,
      "kind" => persisted_event.kind,
      "tags" => tags,
      "content" => persisted_event.content,
      "sig" => Base.encode16(persisted_event.sig, case: :lower)
    }
  end

  defp decode_hex(value, bytes, reason) when is_binary(value) do
    if byte_size(value) == bytes * 2 do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp decode_hex(_value, _bytes, reason), do: {:error, reason}

  defp validate_non_negative_integer(value, _reason)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp validate_non_negative_integer(_value, reason), do: {:error, reason}

  defp validate_binary(value, _reason) when is_binary(value), do: {:ok, value}
  defp validate_binary(_value, reason), do: {:error, reason}

  defp validate_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &valid_tag?/1) do
      {:ok, tags}
    else
      {:error, :invalid_tags}
    end
  end

  defp validate_tags(_tags), do: {:error, :invalid_tags}

  defp valid_tag?(tag) when is_list(tag) do
    tag != [] and Enum.all?(tag, &is_binary/1)
  end

  defp valid_tag?(_tag), do: false

  defp extract_d_tag(tags) do
    tags
    |> Enum.find_value("", fn
      ["d", value | _rest] when is_binary(value) -> value
      _tag -> nil
    end)
  end

  defp extract_expiration(tags) do
    tags
    |> Enum.find_value(fn
      ["expiration", unix_seconds | _rest] -> parse_unix_seconds(unix_seconds)
      _tag -> nil
    end)
  end

  defp parse_unix_seconds(unix_seconds) when is_binary(unix_seconds) do
    case Integer.parse(unix_seconds) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp parse_unix_seconds(_unix_seconds), do: nil
end
