defmodule Parrhesia.Subscriptions.Index do
  @moduledoc """
  ETS-backed subscription index used for fanout candidate narrowing.

  Subscriptions are keyed by `{owner_pid, subscription_id}` and indexed by kind,
  author pubkey, and single-letter tag values.
  """

  use GenServer

  alias Parrhesia.Protocol.Filter

  @wildcard_key :all

  @type subscription_id :: String.t()
  @type owner :: pid()
  @type subscription_key :: {owner(), subscription_id()}
  @type filter :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, :ok)
    else
      GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @spec upsert(owner(), subscription_id(), [filter()]) :: :ok | {:error, term()}
  def upsert(owner_pid, subscription_id, filters) do
    upsert(__MODULE__, owner_pid, subscription_id, filters)
  end

  @spec upsert(GenServer.server(), owner(), subscription_id(), [filter()]) ::
          :ok | {:error, term()}
  def upsert(server, owner_pid, subscription_id, filters) do
    GenServer.call(server, {:upsert, owner_pid, subscription_id, filters})
  end

  @spec remove(owner(), subscription_id()) :: :ok
  def remove(owner_pid, subscription_id) do
    remove(__MODULE__, owner_pid, subscription_id)
  end

  @spec remove(GenServer.server(), owner(), subscription_id()) :: :ok
  def remove(server, owner_pid, subscription_id) do
    GenServer.call(server, {:remove, owner_pid, subscription_id})
  end

  @spec remove_owner(owner()) :: :ok
  def remove_owner(owner_pid) do
    remove_owner(__MODULE__, owner_pid)
  end

  @spec remove_owner(GenServer.server(), owner()) :: :ok
  def remove_owner(server, owner_pid) do
    GenServer.call(server, {:remove_owner, owner_pid})
  end

  @spec candidate_subscription_keys(map()) :: [subscription_key()]
  def candidate_subscription_keys(event) do
    candidate_subscription_keys(__MODULE__, event)
  end

  @spec candidate_subscription_keys(GenServer.server(), map()) :: [subscription_key()]
  def candidate_subscription_keys(server, event) do
    GenServer.call(server, {:candidate_subscription_keys, event})
  end

  @spec fetch_filters(GenServer.server(), owner(), subscription_id()) ::
          {:ok, [filter()]} | :error
  def fetch_filters(server \\ __MODULE__, owner_pid, subscription_id) do
    GenServer.call(server, {:fetch_filters, owner_pid, subscription_id})
  end

  @impl true
  def init(:ok) do
    {:ok,
     %{
       subscriptions_table: :ets.new(:subscriptions_table, [:set, :protected]),
       kind_index_table: :ets.new(:subscription_kind_index, [:bag, :protected]),
       author_index_table: :ets.new(:subscription_author_index, [:bag, :protected]),
       tag_index_table: :ets.new(:subscription_tag_index, [:bag, :protected]),
       kind_wildcard_table: :ets.new(:subscription_kind_wildcard_index, [:bag, :protected]),
       author_wildcard_table: :ets.new(:subscription_author_wildcard_index, [:bag, :protected]),
       tag_wildcard_table: :ets.new(:subscription_tag_wildcard_index, [:bag, :protected]),
       owner_subscriptions: %{},
       owner_monitors: %{},
       monitor_owners: %{}
     }}
  end

  @impl true
  def handle_call({:upsert, owner_pid, subscription_id, filters}, _from, state) do
    with :ok <- validate_upsert_args(owner_pid, subscription_id, filters),
         :ok <- Filter.validate_filters(filters) do
      subscription_key = {owner_pid, subscription_id}
      state = remove_existing_subscription(state, subscription_key)

      index_entries = build_index_entries(filters)

      true = :ets.insert(state.subscriptions_table, {subscription_key, filters, index_entries})
      insert_index_entries(state, subscription_key, index_entries)

      state =
        state
        |> ensure_owner_monitor(owner_pid)
        |> track_owner_subscription(owner_pid, subscription_key)

      {:reply, :ok, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, owner_pid, subscription_id}, _from, state) do
    subscription_key = {owner_pid, subscription_id}
    state = remove_existing_subscription(state, subscription_key)
    {:reply, :ok, state}
  end

  def handle_call({:remove_owner, owner_pid}, _from, state) do
    state = remove_owner_subscriptions(state, owner_pid)
    {:reply, :ok, state}
  end

  def handle_call({:candidate_subscription_keys, event}, _from, state) do
    candidates =
      state
      |> kind_candidates(event)
      |> MapSet.intersection(author_candidates(state, event))
      |> MapSet.intersection(tag_candidates(state, event))
      |> MapSet.to_list()

    {:reply, candidates, state}
  end

  def handle_call({:fetch_filters, owner_pid, subscription_id}, _from, state) do
    subscription_key = {owner_pid, subscription_id}

    case :ets.lookup(state.subscriptions_table, subscription_key) do
      [{^subscription_key, filters, _index_entries}] -> {:reply, {:ok, filters}, state}
      [] -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner_pid, _reason}, state) do
    case Map.get(state.monitor_owners, monitor_ref) do
      ^owner_pid ->
        state = remove_owner_subscriptions(state, owner_pid)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp validate_upsert_args(owner_pid, subscription_id, filters)
       when is_pid(owner_pid) and is_binary(subscription_id) and is_list(filters),
       do: :ok

  defp validate_upsert_args(_owner_pid, _subscription_id, _filters),
    do: {:error, :invalid_subscription}

  defp remove_existing_subscription(state, subscription_key) do
    case :ets.lookup(state.subscriptions_table, subscription_key) do
      [{^subscription_key, _filters, index_entries}] ->
        true = :ets.delete(state.subscriptions_table, subscription_key)
        delete_index_entries(state, subscription_key, index_entries)
        untrack_owner_subscription(state, subscription_key)

      [] ->
        state
    end
  end

  defp build_index_entries(filters) do
    Enum.reduce(filters, empty_index_entries(), fn filter, acc ->
      acc
      |> index_kinds(filter)
      |> index_authors(filter)
      |> index_tags(filter)
    end)
  end

  defp empty_index_entries do
    %{
      kinds: MapSet.new(),
      kind_wildcard?: false,
      authors: MapSet.new(),
      author_wildcard?: false,
      tags: MapSet.new(),
      tag_wildcard?: false
    }
  end

  defp index_kinds(acc, filter) do
    case Map.get(filter, "kinds") do
      kinds when is_list(kinds) ->
        Enum.reduce(kinds, acc, fn kind, acc_inner ->
          %{acc_inner | kinds: MapSet.put(acc_inner.kinds, kind)}
        end)

      _other ->
        %{acc | kind_wildcard?: true}
    end
  end

  defp index_authors(acc, filter) do
    case Map.get(filter, "authors") do
      authors when is_list(authors) ->
        Enum.reduce(authors, acc, fn author, acc_inner ->
          %{acc_inner | authors: MapSet.put(acc_inner.authors, author)}
        end)

      _other ->
        %{acc | author_wildcard?: true}
    end
  end

  defp index_tags(acc, filter) do
    case tag_filters(filter) do
      [] ->
        %{acc | tag_wildcard?: true}

      extracted_tag_filters ->
        tags =
          Enum.reduce(extracted_tag_filters, acc.tags, fn {tag_name, values}, tags_acc ->
            put_tag_values(tags_acc, tag_name, values)
          end)

        %{acc | tags: tags}
    end
  end

  defp tag_filters(filter) do
    Enum.reduce(filter, [], fn
      {<<"#", tag_name::binary-size(1)>>, values}, collected when is_list(values) ->
        [{tag_name, values} | collected]

      _entry, collected ->
        collected
    end)
  end

  defp put_tag_values(tags, tag_name, values) do
    Enum.reduce(values, tags, fn value, tags_acc ->
      MapSet.put(tags_acc, {tag_name, value})
    end)
  end

  defp insert_index_entries(state, subscription_key, index_entries) do
    Enum.each(index_entries.kinds, fn kind ->
      true = :ets.insert(state.kind_index_table, {kind, subscription_key})
    end)

    if index_entries.kind_wildcard? do
      true = :ets.insert(state.kind_wildcard_table, {@wildcard_key, subscription_key})
    end

    Enum.each(index_entries.authors, fn author ->
      true = :ets.insert(state.author_index_table, {author, subscription_key})
    end)

    if index_entries.author_wildcard? do
      true = :ets.insert(state.author_wildcard_table, {@wildcard_key, subscription_key})
    end

    Enum.each(index_entries.tags, fn {tag_name, value} ->
      true = :ets.insert(state.tag_index_table, {{tag_name, value}, subscription_key})
    end)

    if index_entries.tag_wildcard? do
      true = :ets.insert(state.tag_wildcard_table, {@wildcard_key, subscription_key})
    end

    :ok
  end

  defp delete_index_entries(state, subscription_key, index_entries) do
    Enum.each(index_entries.kinds, fn kind ->
      true = :ets.delete_object(state.kind_index_table, {kind, subscription_key})
    end)

    if index_entries.kind_wildcard? do
      true = :ets.delete_object(state.kind_wildcard_table, {@wildcard_key, subscription_key})
    end

    Enum.each(index_entries.authors, fn author ->
      true = :ets.delete_object(state.author_index_table, {author, subscription_key})
    end)

    if index_entries.author_wildcard? do
      true = :ets.delete_object(state.author_wildcard_table, {@wildcard_key, subscription_key})
    end

    Enum.each(index_entries.tags, fn {tag_name, value} ->
      true = :ets.delete_object(state.tag_index_table, {{tag_name, value}, subscription_key})
    end)

    if index_entries.tag_wildcard? do
      true = :ets.delete_object(state.tag_wildcard_table, {@wildcard_key, subscription_key})
    end

    :ok
  end

  defp ensure_owner_monitor(state, owner_pid) do
    case Map.fetch(state.owner_monitors, owner_pid) do
      {:ok, _monitor_ref} ->
        state

      :error ->
        monitor_ref = Process.monitor(owner_pid)

        state
        |> put_in([:owner_monitors, owner_pid], monitor_ref)
        |> put_in([:monitor_owners, monitor_ref], owner_pid)
    end
  end

  defp track_owner_subscription(state, owner_pid, subscription_key) do
    current = Map.get(state.owner_subscriptions, owner_pid, MapSet.new())
    next = MapSet.put(current, subscription_key)
    put_in(state, [:owner_subscriptions, owner_pid], next)
  end

  defp untrack_owner_subscription(state, {owner_pid, _subscription_id} = subscription_key) do
    current = Map.get(state.owner_subscriptions, owner_pid, MapSet.new())
    remaining = MapSet.delete(current, subscription_key)

    if MapSet.size(remaining) == 0 do
      state
      |> maybe_demonitor_owner(owner_pid)
      |> update_in([:owner_subscriptions], &Map.delete(&1, owner_pid))
    else
      put_in(state, [:owner_subscriptions, owner_pid], remaining)
    end
  end

  defp maybe_demonitor_owner(state, owner_pid) do
    case Map.pop(state.owner_monitors, owner_pid) do
      {nil, _owner_monitors} ->
        state

      {monitor_ref, owner_monitors} ->
        true = Process.demonitor(monitor_ref, [:flush])

        state
        |> Map.put(:owner_monitors, owner_monitors)
        |> update_in([:monitor_owners], &Map.delete(&1, monitor_ref))
    end
  end

  defp remove_owner_subscriptions(state, owner_pid) do
    subscription_keys = Map.get(state.owner_subscriptions, owner_pid, MapSet.new())

    state =
      Enum.reduce(subscription_keys, state, fn subscription_key, acc ->
        remove_existing_subscription(acc, subscription_key)
      end)

    state
    |> maybe_demonitor_owner(owner_pid)
    |> update_in([:owner_subscriptions], &Map.delete(&1, owner_pid))
  end

  defp kind_candidates(state, event) do
    event
    |> Map.get("kind")
    |> index_candidates_for_value(state.kind_index_table, state.kind_wildcard_table)
  end

  defp author_candidates(state, event) do
    event
    |> Map.get("pubkey")
    |> index_candidates_for_value(state.author_index_table, state.author_wildcard_table)
  end

  defp tag_candidates(state, event) do
    tag_pairs = event_tag_pairs(Map.get(event, "tags"))
    wildcard_candidates = lookup_candidates(state.tag_wildcard_table, @wildcard_key)

    if MapSet.size(tag_pairs) == 0 do
      wildcard_candidates
    else
      matched_candidates =
        Enum.reduce(tag_pairs, MapSet.new(), fn {tag_name, value}, acc ->
          MapSet.union(acc, lookup_candidates(state.tag_index_table, {tag_name, value}))
        end)

      MapSet.union(matched_candidates, wildcard_candidates)
    end
  end

  defp index_candidates_for_value(value, index_table, wildcard_table) do
    wildcard_candidates = lookup_candidates(wildcard_table, @wildcard_key)

    if is_nil(value) do
      wildcard_candidates
    else
      value_candidates = lookup_candidates(index_table, value)
      MapSet.union(value_candidates, wildcard_candidates)
    end
  end

  defp lookup_candidates(table, key) do
    table
    |> :ets.lookup(key)
    |> Enum.reduce(MapSet.new(), fn
      {^key, subscription_key}, acc -> MapSet.put(acc, subscription_key)
      _entry, acc -> acc
    end)
  end

  defp event_tag_pairs(tags) when is_list(tags) do
    Enum.reduce(tags, MapSet.new(), fn
      [tag_name, value | _rest], acc when is_binary(tag_name) and is_binary(value) ->
        MapSet.put(acc, {tag_name, value})

      _tag, acc ->
        acc
    end)
  end

  defp event_tag_pairs(_tags), do: MapSet.new()
end
