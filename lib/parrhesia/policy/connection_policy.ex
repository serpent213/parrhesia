defmodule Parrhesia.Policy.ConnectionPolicy do
  @moduledoc """
  Connection/session-level policy checks shared by websocket and management entrypoints.
  """

  alias Parrhesia.Storage

  @spec authorize_remote_ip(tuple() | String.t() | nil) :: :ok | {:error, :ip_blocked}
  def authorize_remote_ip(remote_ip) do
    case normalize_ip(remote_ip) do
      nil ->
        :ok

      normalized_ip ->
        case Storage.moderation().ip_blocked?(%{}, normalized_ip) do
          {:ok, true} -> {:error, :ip_blocked}
          _other -> :ok
        end
    end
  end

  @spec authorize_authenticated_pubkey(String.t()) :: :ok | {:error, :pubkey_not_allowed}
  def authorize_authenticated_pubkey(pubkey) when is_binary(pubkey) do
    if allowlist_active?() do
      case Storage.moderation().pubkey_allowed?(%{}, pubkey) do
        {:ok, true} -> :ok
        _other -> {:error, :pubkey_not_allowed}
      end
    else
      :ok
    end
  end

  @spec authorize_authenticated_pubkeys(MapSet.t(String.t())) ::
          :ok | {:error, :auth_required | :pubkey_not_allowed}
  def authorize_authenticated_pubkeys(authenticated_pubkeys) do
    if allowlist_active?() do
      cond do
        MapSet.size(authenticated_pubkeys) == 0 ->
          {:error, :auth_required}

        Enum.any?(authenticated_pubkeys, &(authorize_authenticated_pubkey(&1) == :ok)) ->
          :ok

        true ->
          {:error, :pubkey_not_allowed}
      end
    else
      :ok
    end
  end

  defp allowlist_active? do
    case Storage.moderation().has_allowed_pubkeys?(%{}) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp normalize_ip(nil), do: nil
  defp normalize_ip({_, _, _, _} = remote_ip), do: :inet.ntoa(remote_ip) |> to_string()

  defp normalize_ip({_, _, _, _, _, _, _, _} = remote_ip),
    do: :inet.ntoa(remote_ip) |> to_string()

  defp normalize_ip(remote_ip) when is_binary(remote_ip), do: remote_ip
  defp normalize_ip(_remote_ip), do: nil
end
