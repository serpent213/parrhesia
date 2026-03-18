defmodule Parrhesia.Storage.Adapters.Postgres.Events do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Events`.
  """

  import Ecto.Query

  alias Parrhesia.PostgresRepos
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Events
  @trigram_fallback_max_single_term_length 4
  @trigram_fallback_pattern ~r/[^\p{L}\p{N}\s"]/u
  @fts_match_fragment "to_tsvector('simple', ?) @@ websearch_to_tsquery('simple', ?)"
  @fts_rank_fragment "ts_rank_cd(to_tsvector('simple', ?), websearch_to_tsquery('simple', ?))"
  @trigram_rank_fragment "word_similarity(lower(?), lower(?))"

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
            tags: event.tags,
            content: event.content,
            sig: event.sig
          }
        )

      repo = read_repo()

      case repo.one(event_query) do
        nil ->
          {:ok, nil}

        persisted_event ->
          {:ok, to_nostr_event(persisted_event)}
      end
    end
  end

  @impl true
  def query(_context, filters, opts) when is_list(opts) do
    with :ok <- Filter.validate_filters(filters) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      repo = read_repo()

      persisted_events =
        filters
        |> Enum.flat_map(fn filter ->
          filter
          |> event_query_for_filter(now, opts)
          |> repo.all()
        end)
        |> deduplicate_events()
        |> sort_persisted_events(filters)
        |> maybe_apply_query_limit(opts)

      {:ok, Enum.map(persisted_events, &to_nostr_event/1)}
    end
  end

  def query(_context, _filters, _opts), do: {:error, :invalid_opts}

  @impl true
  def query_event_refs(_context, filters, opts) when is_list(opts) do
    with :ok <- Filter.validate_filters(filters) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      {:ok, fetch_event_refs(filters, now, opts)}
    end
  end

  def query_event_refs(_context, _filters, _opts), do: {:error, :invalid_opts}

  @impl true
  def count(_context, filters, opts) when is_list(opts) do
    with :ok <- Filter.validate_filters(filters) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      {:ok, count_events(filters, now, opts)}
    end
  end

  def count(_context, _filters, _opts), do: {:error, :invalid_opts}

  @impl true
  def delete_by_request(_context, event) do
    with {:ok, deleter_pubkey} <- decode_hex(Map.get(event, "pubkey"), 32, :invalid_pubkey),
         {:ok, delete_targets} <- extract_delete_targets(event) do
      deleted_at = System.system_time(:second)

      deleted_by_id_count =
        delete_targets
        |> Map.get(:event_ids, [])
        |> delete_events_by_ids(deleter_pubkey, deleted_at)

      deleted_by_coordinate_count =
        delete_targets
        |> Map.get(:coordinates, [])
        |> delete_events_by_coordinates(deleter_pubkey, deleted_at)

      {:ok, deleted_by_id_count + deleted_by_coordinate_count}
    end
  end

  defp delete_events_by_ids([], _deleter_pubkey, _deleted_at), do: 0

  defp delete_events_by_ids(delete_ids, deleter_pubkey, deleted_at) do
    query =
      from(stored_event in "events",
        where:
          stored_event.id in ^delete_ids and
            stored_event.pubkey == ^deleter_pubkey and
            is_nil(stored_event.deleted_at)
      )

    {count, _result} = Repo.update_all(query, set: [deleted_at: deleted_at])
    count
  end

  defp delete_events_by_coordinates([], _deleter_pubkey, _deleted_at), do: 0

  defp delete_events_by_coordinates(coordinates, deleter_pubkey, deleted_at) do
    relevant_coordinates =
      Enum.filter(coordinates, fn coordinate ->
        coordinate.pubkey == deleter_pubkey and
          (replaceable_kind?(coordinate.kind) or addressable_kind?(coordinate.kind))
      end)

    if relevant_coordinates == [] do
      0
    else
      dynamic_conditions =
        Enum.reduce(relevant_coordinates, dynamic(false), fn coordinate, acc ->
          coordinate_condition =
            coordinate_delete_condition(coordinate, deleter_pubkey)

          dynamic([stored_event], ^acc or ^coordinate_condition)
        end)

      query =
        from(stored_event in "events",
          where: is_nil(stored_event.deleted_at)
        )
        |> where(^dynamic_conditions)

      {count, _result} = Repo.update_all(query, set: [deleted_at: deleted_at])
      count
    end
  end

  defp coordinate_delete_condition(coordinate, deleter_pubkey) do
    if addressable_kind?(coordinate.kind) do
      dynamic(
        [stored_event],
        stored_event.kind == ^coordinate.kind and
          stored_event.pubkey == ^deleter_pubkey and
          stored_event.d_tag == ^coordinate.d_tag
      )
    else
      dynamic(
        [stored_event],
        stored_event.kind == ^coordinate.kind and
          stored_event.pubkey == ^deleter_pubkey
      )
    end
  end

  @impl true
  def vanish(_context, event) do
    with {:ok, pubkey} <- decode_hex(Map.get(event, "pubkey"), 32, :invalid_pubkey),
         {:ok, created_at} <-
           validate_non_negative_integer(Map.get(event, "created_at"), :invalid_created_at) do
      own_events_query =
        from(stored_event in "events",
          where: stored_event.pubkey == ^pubkey and stored_event.created_at <= ^created_at
        )

      giftwrap_query =
        from(stored_event in "events",
          join: tag in "event_tags",
          on: tag.event_created_at == stored_event.created_at and tag.event_id == stored_event.id,
          where:
            stored_event.kind == 1059 and
              tag.name == "p" and
              tag.value == ^Base.encode16(pubkey, case: :lower) and
              stored_event.created_at <= ^created_at
        )

      {own_events_count, _result} = Repo.delete_all(own_events_query)
      {giftwrap_count, _result} = Repo.delete_all(giftwrap_query)

      {:ok, own_events_count + giftwrap_count}
    end
  end

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
      expires_at =
        tags
        |> extract_expiration()
        |> maybe_apply_mls_group_retention(kind, created_at)

      {:ok,
       %{
         id: id,
         pubkey: pubkey,
         created_at: created_at,
         kind: kind,
         content: content,
         sig: sig,
         d_tag: extract_d_tag(tags),
         expires_at: expires_at,
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
    deleted_at = DateTime.to_unix(now, :second)

    :ok = maybe_upsert_replaceable_state(normalized_event, now, deleted_at)
    :ok = maybe_upsert_addressable_state(normalized_event, now, deleted_at)
    :ok
  end

  defp maybe_upsert_replaceable_state(normalized_event, now, deleted_at) do
    if replaceable_kind?(normalized_event.kind) do
      upsert_replaceable_state_table(normalized_event, now, deleted_at)
    else
      :ok
    end
  end

  defp maybe_upsert_addressable_state(normalized_event, now, deleted_at) do
    if addressable_kind?(normalized_event.kind) do
      upsert_addressable_state_table(normalized_event, now, deleted_at)
    else
      :ok
    end
  end

  defp upsert_replaceable_state_table(normalized_event, now, deleted_at) do
    params = [
      normalized_event.pubkey,
      normalized_event.kind,
      normalized_event.created_at,
      normalized_event.id,
      now,
      now
    ]

    case Repo.query(replaceable_state_upsert_sql(), params) do
      {:ok, %{rows: [row]}} ->
        finalize_state_upsert(row, normalized_event, deleted_at, :replaceable_state_update_failed)

      {:ok, _result} ->
        Repo.rollback(:replaceable_state_update_failed)

      {:error, _reason} ->
        Repo.rollback(:replaceable_state_update_failed)
    end
  end

  defp upsert_addressable_state_table(normalized_event, now, deleted_at) do
    params = [
      normalized_event.pubkey,
      normalized_event.kind,
      normalized_event.d_tag,
      normalized_event.created_at,
      normalized_event.id,
      now,
      now
    ]

    case Repo.query(addressable_state_upsert_sql(), params) do
      {:ok, %{rows: [row]}} ->
        finalize_state_upsert(row, normalized_event, deleted_at, :addressable_state_update_failed)

      {:ok, _result} ->
        Repo.rollback(:addressable_state_update_failed)

      {:error, _reason} ->
        Repo.rollback(:addressable_state_update_failed)
    end
  end

  defp finalize_state_upsert(
         [retired_event_created_at, retired_event_id, winner_event_created_at, winner_event_id],
         normalized_event,
         deleted_at,
         failure_reason
       ) do
    case {winner_event_created_at, winner_event_id} do
      {created_at, event_id}
      when created_at == normalized_event.created_at and event_id == normalized_event.id ->
        maybe_retire_previous_state_event(
          retired_event_created_at,
          retired_event_id,
          deleted_at,
          failure_reason
        )

      {_created_at, _event_id} ->
        retire_event!(
          normalized_event.created_at,
          normalized_event.id,
          deleted_at,
          failure_reason
        )
    end
  end

  defp maybe_retire_previous_state_event(nil, nil, _deleted_at, _failure_reason), do: :ok

  defp maybe_retire_previous_state_event(
         retired_event_created_at,
         retired_event_id,
         deleted_at,
         failure_reason
       ) do
    retire_event!(retired_event_created_at, retired_event_id, deleted_at, failure_reason)
  end

  defp retire_event!(event_created_at, event_id, deleted_at, failure_reason) do
    {updated, _result} =
      Repo.update_all(
        from(event in "events",
          where:
            event.created_at == ^event_created_at and
              event.id == ^event_id and
              is_nil(event.deleted_at)
        ),
        set: [deleted_at: deleted_at]
      )

    if updated in [0, 1] do
      :ok
    else
      Repo.rollback(failure_reason)
    end
  end

  defp replaceable_kind?(kind), do: kind in [0, 3] or (kind >= 10_000 and kind < 20_000)

  defp addressable_kind?(kind), do: kind >= 30_000 and kind < 40_000

  defp replaceable_state_upsert_sql do
    """
    WITH inserted AS (
      INSERT INTO replaceable_event_state (
        pubkey,
        kind,
        event_created_at,
        event_id,
        inserted_at,
        updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (pubkey, kind) DO NOTHING
      RETURNING
        NULL::bigint AS retired_event_created_at,
        NULL::bytea AS retired_event_id,
        event_created_at AS winner_event_created_at,
        event_id AS winner_event_id
    ),
    updated AS (
      UPDATE replaceable_event_state AS state
      SET
        event_created_at = $3,
        event_id = $4,
        updated_at = $6
      FROM (
        SELECT current.event_created_at, current.event_id
        FROM replaceable_event_state AS current
        WHERE current.pubkey = $1 AND current.kind = $2
        FOR UPDATE
      ) AS previous
      WHERE
        NOT EXISTS (SELECT 1 FROM inserted)
        AND state.pubkey = $1
        AND state.kind = $2
        AND (
          state.event_created_at < $3
          OR (state.event_created_at = $3 AND state.event_id > $4)
        )
      RETURNING
        previous.event_created_at AS retired_event_created_at,
        previous.event_id AS retired_event_id,
        state.event_created_at AS winner_event_created_at,
        state.event_id AS winner_event_id
    ),
    current AS (
      SELECT
        NULL::bigint AS retired_event_created_at,
        NULL::bytea AS retired_event_id,
        state.event_created_at AS winner_event_created_at,
        state.event_id AS winner_event_id
      FROM replaceable_event_state AS state
      WHERE
        NOT EXISTS (SELECT 1 FROM inserted)
        AND NOT EXISTS (SELECT 1 FROM updated)
        AND state.pubkey = $1
        AND state.kind = $2
    )
    SELECT *
    FROM inserted
    UNION ALL
    SELECT *
    FROM updated
    UNION ALL
    SELECT *
    FROM current
    LIMIT 1
    """
  end

  defp addressable_state_upsert_sql do
    """
    WITH inserted AS (
      INSERT INTO addressable_event_state (
        pubkey,
        kind,
        d_tag,
        event_created_at,
        event_id,
        inserted_at,
        updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      ON CONFLICT (pubkey, kind, d_tag) DO NOTHING
      RETURNING
        NULL::bigint AS retired_event_created_at,
        NULL::bytea AS retired_event_id,
        event_created_at AS winner_event_created_at,
        event_id AS winner_event_id
    ),
    updated AS (
      UPDATE addressable_event_state AS state
      SET
        event_created_at = $4,
        event_id = $5,
        updated_at = $7
      FROM (
        SELECT current.event_created_at, current.event_id
        FROM addressable_event_state AS current
        WHERE current.pubkey = $1 AND current.kind = $2 AND current.d_tag = $3
        FOR UPDATE
      ) AS previous
      WHERE
        NOT EXISTS (SELECT 1 FROM inserted)
        AND state.pubkey = $1
        AND state.kind = $2
        AND state.d_tag = $3
        AND (
          state.event_created_at < $4
          OR (state.event_created_at = $4 AND state.event_id > $5)
        )
      RETURNING
        previous.event_created_at AS retired_event_created_at,
        previous.event_id AS retired_event_id,
        state.event_created_at AS winner_event_created_at,
        state.event_id AS winner_event_id
    ),
    current AS (
      SELECT
        NULL::bigint AS retired_event_created_at,
        NULL::bytea AS retired_event_id,
        state.event_created_at AS winner_event_created_at,
        state.event_id AS winner_event_id
      FROM addressable_event_state AS state
      WHERE
        NOT EXISTS (SELECT 1 FROM inserted)
        AND NOT EXISTS (SELECT 1 FROM updated)
        AND state.pubkey = $1
        AND state.kind = $2
        AND state.d_tag = $3
    )
    SELECT *
    FROM inserted
    UNION ALL
    SELECT *
    FROM updated
    UNION ALL
    SELECT *
    FROM current
    LIMIT 1
    """
  end

  defp event_row(normalized_event, now) do
    %{
      id: normalized_event.id,
      pubkey: normalized_event.pubkey,
      created_at: normalized_event.created_at,
      kind: normalized_event.kind,
      tags: normalized_event.tags,
      content: normalized_event.content,
      sig: normalized_event.sig,
      d_tag: normalized_event.d_tag,
      expires_at: normalized_event.expires_at,
      inserted_at: now,
      updated_at: now
    }
  end

  defp event_query_for_filter(filter, now, opts) do
    search_plan = search_plan(Map.get(filter, "search"))
    {base_query, remaining_tag_filters} = event_source_query(filter, now)

    base_query
    |> apply_common_event_filters(filter, remaining_tag_filters, opts, search_plan)
    |> maybe_order_by_search_rank(search_plan)
    |> select([event: event], %{
      id: event.id,
      pubkey: event.pubkey,
      created_at: event.created_at,
      kind: event.kind,
      tags: event.tags,
      content: event.content,
      sig: event.sig
    })
    |> maybe_select_search_score(search_plan)
    |> maybe_limit_query(effective_filter_limit(filter, opts))
  end

  defp event_id_query_for_filter(filter, now, opts) do
    search_plan = search_plan(Map.get(filter, "search"))
    {base_query, remaining_tag_filters} = event_source_query(filter, now)

    base_query
    |> apply_common_event_filters(filter, remaining_tag_filters, opts, search_plan)
    |> select([event: event], event.id)
  end

  defp event_id_distinct_union_query_for_filters([], now, _opts) do
    from(event in "events",
      where: event.created_at > ^now and event.created_at < ^now,
      select: event.id
    )
  end

  defp event_id_distinct_union_query_for_filters([first_filter | rest_filters], now, opts) do
    Enum.reduce(rest_filters, event_id_query_for_filter(first_filter, now, opts), fn filter,
                                                                                     acc ->
      union(acc, ^event_id_query_for_filter(filter, now, opts))
    end)
  end

  defp event_ref_query_for_filter(filter, now, opts) do
    search_plan = search_plan(Map.get(filter, "search"))
    {base_query, remaining_tag_filters} = event_source_query(filter, now)

    base_query
    |> apply_common_event_filters(filter, remaining_tag_filters, opts, search_plan)
    |> order_by([event: event], asc: event.created_at, asc: event.id)
    |> select([event: event], %{
      created_at: event.created_at,
      id: event.id
    })
    |> maybe_limit_query(effective_filter_limit(filter, opts))
  end

  defp event_ref_union_query_for_filters([], now, _opts) do
    from(event in "events",
      where: event.created_at > ^now and event.created_at < ^now,
      select: %{created_at: event.created_at, id: event.id}
    )
  end

  defp event_ref_union_query_for_filters([first_filter | rest_filters], now, opts) do
    Enum.reduce(rest_filters, event_ref_query_for_filter(first_filter, now, opts), fn filter,
                                                                                      acc ->
      union_all(acc, ^event_ref_query_for_filter(filter, now, opts))
    end)
  end

  defp fetch_event_refs([filter], now, opts) do
    query =
      filter
      |> event_ref_query_for_filter(now, opts)
      |> maybe_limit_query(Keyword.get(opts, :limit))

    read_repo()
    |> then(fn repo -> repo.all(query) end)
  end

  defp fetch_event_refs(filters, now, opts) do
    query =
      filters
      |> event_ref_union_query_for_filters(now, opts)
      |> subquery()
      |> then(fn union_query ->
        from(ref in union_query,
          group_by: [ref.created_at, ref.id],
          order_by: [asc: ref.created_at, asc: ref.id],
          select: %{created_at: ref.created_at, id: ref.id}
        )
      end)
      |> maybe_limit_query(Keyword.get(opts, :limit))

    read_repo()
    |> then(fn repo -> repo.all(query) end)
  end

  defp count_events([filter], now, opts) do
    query =
      filter
      |> event_id_query_for_filter(now, opts)
      |> subquery()
      |> then(fn query ->
        from(event in query, select: count())
      end)

    read_repo()
    |> then(fn repo -> repo.one(query) end)
  end

  defp count_events(filters, now, opts) do
    query =
      filters
      |> event_id_distinct_union_query_for_filters(now, opts)
      |> subquery()
      |> then(fn union_query ->
        from(event in union_query, select: count())
      end)

    read_repo()
    |> then(fn repo -> repo.one(query) end)
  end

  defp event_source_query(filter, now) do
    tag_filters = tag_filters(filter)

    case primary_tag_filter(tag_filters) do
      nil ->
        {from(event in "events",
           as: :event,
           where:
             is_nil(event.deleted_at) and
               (is_nil(event.expires_at) or event.expires_at > ^now)
         ), []}

      {tag_name, values} = primary_tag_filter ->
        remaining_tag_filters = List.delete(tag_filters, primary_tag_filter)

        {from(tag in "event_tags",
           as: :primary_tag,
           where: tag.name == ^tag_name and tag.value in ^values,
           join: event in "events",
           as: :event,
           on: event.created_at == tag.event_created_at and event.id == tag.event_id,
           where:
             is_nil(event.deleted_at) and
               (is_nil(event.expires_at) or event.expires_at > ^now),
           distinct: [event.created_at, event.id]
         ), remaining_tag_filters}
    end
  end

  defp apply_common_event_filters(query, filter, remaining_tag_filters, opts, search_plan) do
    query
    |> maybe_filter_ids(Map.get(filter, "ids"))
    |> maybe_filter_authors(Map.get(filter, "authors"))
    |> maybe_filter_kinds(Map.get(filter, "kinds"))
    |> maybe_filter_since(Map.get(filter, "since"))
    |> maybe_filter_until(Map.get(filter, "until"))
    |> maybe_filter_search(search_plan)
    |> filter_by_tag_filters(remaining_tag_filters)
    |> maybe_restrict_giftwrap_access(filter, opts)
  end

  defp primary_tag_filter([]), do: nil

  defp primary_tag_filter(tag_filters) do
    Enum.find(tag_filters, fn {tag_name, _values} -> tag_name in ["h", "i"] end) ||
      List.first(tag_filters)
  end

  defp maybe_filter_ids(query, nil), do: query

  defp maybe_filter_ids(query, ids) do
    decoded_ids = decode_hex_list(ids, :lower)
    where(query, [event: event], event.id in ^decoded_ids)
  end

  defp maybe_filter_authors(query, nil), do: query

  defp maybe_filter_authors(query, authors) do
    decoded_authors = decode_hex_list(authors, :lower)
    where(query, [event: event], event.pubkey in ^decoded_authors)
  end

  defp maybe_filter_kinds(query, nil), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [event: event], event.kind in ^kinds)

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since),
    do: where(query, [event: event], event.created_at >= ^since)

  defp maybe_filter_until(query, nil), do: query

  defp maybe_filter_until(query, until),
    do: where(query, [event: event], event.created_at <= ^until)

  defp maybe_filter_search(query, nil), do: query

  defp maybe_filter_search(query, %{mode: :fts, query: search}) do
    where(
      query,
      [event: event],
      fragment(@fts_match_fragment, event.content, ^search)
    )
  end

  defp maybe_filter_search(query, %{mode: :trigram, query: search}) do
    escaped_search = escape_like_pattern(search)
    where(query, [event: event], ilike(event.content, ^"%#{escaped_search}%"))
  end

  defp escape_like_pattern(search) do
    search
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp filter_by_tag_filters(query, tag_filters) do
    Enum.reduce(tag_filters, query, fn {tag_name, values}, acc ->
      where(
        acc,
        [event: event],
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

  defp maybe_restrict_giftwrap_access(query, filter, opts) do
    requester_pubkeys = Keyword.get(opts, :requester_pubkeys, [])

    cond do
      targets_giftwrap?(filter) and requester_pubkeys != [] ->
        where(
          query,
          [event: event],
          fragment(
            "EXISTS (SELECT 1 FROM event_tags AS tag WHERE tag.event_created_at = ? AND tag.event_id = ? AND tag.name = 'p' AND tag.value = ANY(?))",
            event.created_at,
            event.id,
            type(^requester_pubkeys, {:array, :string})
          )
        )

      targets_giftwrap?(filter) ->
        where(query, [event: _event], false)

      true ->
        query
    end
  end

  defp targets_giftwrap?(filter) do
    case Map.get(filter, "kinds") do
      kinds when is_list(kinds) -> 1059 in kinds
      _other -> false
    end
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

  defp maybe_order_by_search_rank(query, nil) do
    order_by(query, [event: event], desc: event.created_at, asc: event.id)
  end

  defp maybe_order_by_search_rank(query, %{mode: :fts, query: search}) do
    order_by(
      query,
      [event: event],
      desc: fragment(@fts_rank_fragment, event.content, ^search),
      desc: event.created_at,
      asc: event.id
    )
  end

  defp maybe_order_by_search_rank(query, %{mode: :trigram, query: search}) do
    order_by(
      query,
      [event: event],
      desc: fragment(@trigram_rank_fragment, ^search, event.content),
      desc: event.created_at,
      asc: event.id
    )
  end

  defp maybe_select_search_score(query, nil), do: query

  defp maybe_select_search_score(query, %{mode: :fts, query: search}) do
    select_merge(
      query,
      [event: event],
      %{search_score: fragment(@fts_rank_fragment, event.content, ^search)}
    )
  end

  defp maybe_select_search_score(query, %{mode: :trigram, query: search}) do
    select_merge(
      query,
      [event: event],
      %{search_score: fragment(@trigram_rank_fragment, ^search, event.content)}
    )
  end

  defp search_plan(nil), do: nil

  defp search_plan(search) when is_binary(search) do
    normalized_search = String.trim(search)

    cond do
      normalized_search == "" ->
        nil

      trigram_fallback_search?(normalized_search) ->
        %{mode: :trigram, query: normalized_search}

      true ->
        %{mode: :fts, query: normalized_search}
    end
  end

  defp trigram_fallback_search?(search) do
    String.match?(search, @trigram_fallback_pattern) or short_single_term_search?(search)
  end

  defp short_single_term_search?(search) do
    case String.split(search, ~r/\s+/, trim: true) do
      [term] -> String.length(term) <= @trigram_fallback_max_single_term_length
      _other -> false
    end
  end

  defp deduplicate_events(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      Map.update(acc, event.id, event, fn existing -> preferred_event(existing, event) end)
    end)
    |> Map.values()
  end

  defp sort_persisted_events(events, filters) do
    if Enum.any?(filters, &search_filter?/1) do
      Enum.sort(events, &search_result_sorter/2)
    else
      Enum.sort(events, &chronological_sorter/2)
    end
  end

  defp maybe_apply_query_limit(events, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(events, limit)
      _other -> events
    end
  end

  defp to_nostr_event(persisted_event) do
    %{
      "id" => Base.encode16(persisted_event.id, case: :lower),
      "pubkey" => Base.encode16(persisted_event.pubkey, case: :lower),
      "created_at" => persisted_event.created_at,
      "kind" => persisted_event.kind,
      "tags" => normalize_persisted_tags(persisted_event.tags),
      "content" => persisted_event.content,
      "sig" => Base.encode16(persisted_event.sig, case: :lower)
    }
  end

  defp preferred_event(existing, candidate) do
    if search_result_sorter(candidate, existing) do
      candidate
    else
      existing
    end
  end

  defp search_filter?(filter) do
    filter
    |> Map.get("search")
    |> search_plan()
    |> Kernel.!=(nil)
  end

  defp search_result_sorter(left, right) do
    left_score = search_score(left)
    right_score = search_score(right)

    cond do
      left_score > right_score -> true
      left_score < right_score -> false
      true -> chronological_sorter(left, right)
    end
  end

  defp chronological_sorter(left, right) do
    cond do
      left.created_at > right.created_at -> true
      left.created_at < right.created_at -> false
      true -> left.id < right.id
    end
  end

  defp search_score(event) do
    event
    |> Map.get(:search_score, 0.0)
    |> case do
      score when is_float(score) -> score
      score when is_integer(score) -> score / 1
      _other -> 0.0
    end
  end

  defp normalize_persisted_tags(tags) when is_list(tags), do: tags
  defp normalize_persisted_tags(_tags), do: []

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

  defp extract_delete_targets(event) do
    with {:ok, targets} <- parse_delete_targets(Map.get(event, "tags", [])) do
      event_ids = targets.event_ids |> Enum.uniq()
      coordinates = targets.coordinates |> Enum.uniq()

      if event_ids == [] and coordinates == [] do
        {:error, :no_delete_targets}
      else
        {:ok, %{event_ids: event_ids, coordinates: coordinates}}
      end
    end
  end

  defp parse_delete_targets(tags) when is_list(tags) do
    Enum.reduce_while(tags, {:ok, %{event_ids: [], coordinates: []}}, fn tag, {:ok, acc} ->
      case parse_delete_target(tag) do
        {:ok, {:event_id, event_id}} ->
          {:cont, {:ok, %{acc | event_ids: [event_id | acc.event_ids]}}}

        {:ok, {:coordinate, coordinate}} ->
          {:cont, {:ok, %{acc | coordinates: [coordinate | acc.coordinates]}}}

        :ignore ->
          {:cont, {:ok, acc}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_delete_targets(_tags), do: {:error, :invalid_delete_target}

  defp parse_delete_target(["e", event_id | _rest]) when is_binary(event_id) do
    case decode_hex(event_id, 32, :invalid_delete_target) do
      {:ok, decoded_event_id} -> {:ok, {:event_id, decoded_event_id}}
      {:error, _reason} -> {:error, :invalid_delete_target}
    end
  end

  defp parse_delete_target(["a", coordinate | _rest]) when is_binary(coordinate) do
    case parse_address_coordinate(coordinate) do
      {:ok, parsed_coordinate} -> {:ok, {:coordinate, parsed_coordinate}}
      {:error, _reason} -> {:error, :invalid_delete_target}
    end
  end

  defp parse_delete_target(_tag), do: :ignore

  defp parse_address_coordinate(coordinate) do
    case String.split(coordinate, ":", parts: 3) do
      [kind_part, pubkey_hex, d_tag] ->
        with {kind, ""} <- Integer.parse(kind_part),
             true <- kind >= 0,
             {:ok, pubkey} <- decode_hex(pubkey_hex, 32, :invalid_delete_target) do
          {:ok, %{kind: kind, pubkey: pubkey, d_tag: d_tag}}
        else
          _other -> {:error, :invalid_delete_target}
        end

      _other ->
        {:error, :invalid_delete_target}
    end
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

  defp maybe_apply_mls_group_retention(nil, 445, created_at) do
    ttl =
      :parrhesia
      |> Application.get_env(:policies, [])
      |> Keyword.get(:mls_group_event_ttl_seconds, 300)

    if is_integer(ttl) and ttl > 0 do
      created_at + ttl
    else
      nil
    end
  end

  defp maybe_apply_mls_group_retention(expires_at, _kind, _created_at), do: expires_at

  defp read_repo, do: PostgresRepos.read()
end
