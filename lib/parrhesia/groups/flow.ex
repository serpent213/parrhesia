defmodule Parrhesia.Groups.Flow do
  @moduledoc """
  Minimal group and membership flow handling for NIP-29/NIP-43 related kinds.
  """

  alias Parrhesia.Storage

  @membership_request_kind 8_000
  @membership_approval_kind 8_001
  @relay_metadata_kind 28_934
  @relay_admins_kind 28_935
  @relay_rules_kind 28_936
  @membership_event_kind 13_534

  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(event) when is_map(event) do
    case Map.get(event, "kind") do
      @membership_request_kind -> upsert_membership(event, "requested")
      @membership_approval_kind -> upsert_membership(event, "member")
      @membership_event_kind -> upsert_membership(event, "member")
      @relay_metadata_kind -> :ok
      @relay_admins_kind -> :ok
      @relay_rules_kind -> :ok
      _other -> :ok
    end
  end

  @spec group_related_kind?(non_neg_integer()) :: boolean()
  def group_related_kind?(kind)
      when kind in [
             @membership_request_kind,
             @membership_approval_kind,
             @relay_metadata_kind,
             @relay_admins_kind,
             @relay_rules_kind,
             @membership_event_kind
           ],
      do: true

  def group_related_kind?(_kind), do: false

  defp upsert_membership(event, role) do
    with {:ok, group_id} <- group_id_from_event(event),
         {:ok, pubkey} <- pubkey_from_event(event) do
      Storage.groups().put_membership(%{}, %{
        group_id: group_id,
        pubkey: pubkey,
        role: role,
        metadata: %{"source_kind" => Map.get(event, "kind")}
      })
      |> case do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp group_id_from_event(event) do
    group_id =
      event
      |> Map.get("tags", [])
      |> Enum.find_value(fn
        ["h", value | _rest] when is_binary(value) and value != "" -> value
        _tag -> nil
      end)

    case group_id do
      nil -> {:error, :missing_group_id}
      value -> {:ok, value}
    end
  end

  defp pubkey_from_event(%{"pubkey" => pubkey}) when is_binary(pubkey), do: {:ok, pubkey}
  defp pubkey_from_event(_event), do: {:error, :missing_pubkey}
end
