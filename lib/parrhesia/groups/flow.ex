defmodule Parrhesia.Groups.Flow do
  @moduledoc """
  Relay access membership projection backed by the shared group storage adapter.
  """

  alias Parrhesia.Storage

  @relay_access_group_id "__relay_access__"
  @add_user_kind 8_000
  @remove_user_kind 8_001
  @join_request_kind 28_934
  @invite_request_kind 28_935
  @leave_request_kind 28_936
  @membership_list_kind 13_534

  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(event) when is_map(event) do
    case Map.get(event, "kind") do
      @join_request_kind -> put_member(event, membership_pubkey_from_event(event))
      @leave_request_kind -> delete_member(event, membership_pubkey_from_event(event))
      @add_user_kind -> put_member(event, tagged_pubkey(event, "p"))
      @remove_user_kind -> delete_member(event, tagged_pubkey(event, "p"))
      @membership_list_kind -> replace_membership_snapshot(event)
      @invite_request_kind -> :ok
      _other -> :ok
    end
  end

  @spec relay_access_kind?(non_neg_integer()) :: boolean()
  def relay_access_kind?(kind)
      when kind in [
             @add_user_kind,
             @remove_user_kind,
             @join_request_kind,
             @invite_request_kind,
             @leave_request_kind,
             @membership_list_kind
           ],
      do: true

  def relay_access_kind?(_kind), do: false

  @spec get_membership(binary()) :: {:ok, map() | nil} | {:error, term()}
  def get_membership(pubkey) when is_binary(pubkey) do
    Storage.groups().get_membership(%{}, @relay_access_group_id, pubkey)
  end

  @spec list_memberships() :: {:ok, [map()]} | {:error, term()}
  def list_memberships do
    Storage.groups().list_memberships(%{}, @relay_access_group_id)
  end

  defp put_member(event, {:ok, pubkey}) do
    with {:ok, metadata} <- membership_metadata(event) do
      Storage.groups().put_membership(%{}, %{
        group_id: @relay_access_group_id,
        pubkey: pubkey,
        role: "member",
        metadata: metadata
      })
      |> case do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp put_member(_event, {:error, reason}), do: {:error, reason}

  defp delete_member(_event, {:ok, pubkey}) do
    Storage.groups().delete_membership(%{}, @relay_access_group_id, pubkey)
  end

  defp delete_member(_event, {:error, reason}), do: {:error, reason}

  defp replace_membership_snapshot(event) do
    with {:ok, tagged_members} <- tagged_pubkeys(event, "member"),
         {:ok, existing_memberships} <- list_memberships() do
      incoming_pubkeys = MapSet.new(tagged_members)
      existing_pubkeys = MapSet.new(Enum.map(existing_memberships, & &1.pubkey))

      remove_members =
        existing_pubkeys
        |> MapSet.difference(incoming_pubkeys)
        |> MapSet.to_list()

      add_members =
        incoming_pubkeys
        |> MapSet.to_list()

      :ok = remove_memberships(remove_members)
      add_memberships(event, add_members)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp membership_pubkey_from_event(%{"pubkey" => pubkey}) when is_binary(pubkey),
    do: {:ok, pubkey}

  defp membership_pubkey_from_event(_event), do: {:error, :missing_pubkey}

  defp tagged_pubkey(event, tag_name) do
    event
    |> tagged_pubkeys(tag_name)
    |> case do
      {:ok, [pubkey]} -> {:ok, pubkey}
      {:ok, []} -> {:error, :missing_pubkey}
      {:ok, _pubkeys} -> {:error, :invalid_pubkey}
    end
  end

  defp tagged_pubkeys(event, tag_name) do
    pubkeys =
      event
      |> Map.get("tags", [])
      |> Enum.flat_map(fn
        [^tag_name, pubkey | _rest] when is_binary(pubkey) and pubkey != "" -> [pubkey]
        _tag -> []
      end)

    {:ok, Enum.uniq(pubkeys)}
  end

  defp membership_metadata(event) do
    {:ok,
     %{
       "source_kind" => Map.get(event, "kind"),
       "source_event_id" => Map.get(event, "id")
     }}
  end

  defp remove_memberships(pubkeys) when is_list(pubkeys) do
    Enum.each(pubkeys, fn pubkey ->
      :ok = Storage.groups().delete_membership(%{}, @relay_access_group_id, pubkey)
    end)

    :ok
  end

  defp add_memberships(event, pubkeys) when is_list(pubkeys) do
    Enum.reduce_while(pubkeys, :ok, fn pubkey, :ok ->
      case put_member(event, {:ok, pubkey}) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
