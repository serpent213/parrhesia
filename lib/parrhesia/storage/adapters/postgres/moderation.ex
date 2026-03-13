defmodule Parrhesia.Storage.Adapters.Postgres.Moderation do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Moderation`.
  """

  import Ecto.Query

  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Moderation

  @impl true
  def ban_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      upsert_presence_table("banned_pubkeys", :pubkey, normalized_pubkey)
    end
  end

  @impl true
  def unban_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      delete_from_table("banned_pubkeys", :pubkey, normalized_pubkey)
    end
  end

  @impl true
  def pubkey_banned?(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      {:ok, exists_in_table?("banned_pubkeys", :pubkey, normalized_pubkey)}
    end
  end

  @impl true
  def allow_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      upsert_presence_table("allowed_pubkeys", :pubkey, normalized_pubkey)
    end
  end

  @impl true
  def disallow_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      delete_from_table("allowed_pubkeys", :pubkey, normalized_pubkey)
    end
  end

  @impl true
  def pubkey_allowed?(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      {:ok, exists_in_table?("allowed_pubkeys", :pubkey, normalized_pubkey)}
    end
  end

  @impl true
  def ban_event(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id) do
      upsert_presence_table("banned_events", :event_id, normalized_event_id)
    end
  end

  @impl true
  def unban_event(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id) do
      delete_from_table("banned_events", :event_id, normalized_event_id)
    end
  end

  @impl true
  def event_banned?(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id) do
      {:ok, exists_in_table?("banned_events", :event_id, normalized_event_id)}
    end
  end

  @impl true
  def block_ip(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address) do
      upsert_presence_table("blocked_ips", :ip, normalized_ip)
    end
  end

  @impl true
  def unblock_ip(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address) do
      delete_from_table("blocked_ips", :ip, normalized_ip)
    end
  end

  @impl true
  def ip_blocked?(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address) do
      {:ok, exists_in_table?("blocked_ips", :ip, normalized_ip)}
    end
  end

  defp upsert_presence_table(table, field, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {inserted, _result} =
      Repo.insert_all(
        table,
        [
          %{
            field => value,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [field]
      )

    if inserted <= 1 do
      :ok
    else
      {:error, :insert_failed}
    end
  end

  defp delete_from_table(table, field, value) do
    query = from(record in table, where: field(record, ^field) == ^value)
    {_deleted, _result} = Repo.delete_all(query)
    :ok
  end

  defp exists_in_table?(table, field, value) do
    query =
      from(record in table,
        where: field(record, ^field) == ^value,
        select: 1,
        limit: 1
      )

    Repo.one(query) == 1
  end

  defp normalize_hex_or_binary(value, expected_bytes, _reason)
       when is_binary(value) and byte_size(value) == expected_bytes,
       do: {:ok, value}

  defp normalize_hex_or_binary(value, expected_bytes, reason) when is_binary(value) do
    if byte_size(value) == expected_bytes * 2 do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp normalize_hex_or_binary(_value, _expected_bytes, reason), do: {:error, reason}

  defp normalize_ip({_, _, _, _} = ip_tuple), do: {:ok, to_inet(ip_tuple)}
  defp normalize_ip({_, _, _, _, _, _, _, _} = ip_tuple), do: {:ok, to_inet(ip_tuple)}

  defp normalize_ip(ip_address) when is_binary(ip_address) do
    ip_address
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, normalized_ip} -> {:ok, to_inet(normalized_ip)}
      {:error, _reason} -> {:error, :invalid_ip_address}
    end
  end

  defp normalize_ip(_ip_address), do: {:error, :invalid_ip_address}

  defp to_inet({_, _, _, _} = ip_tuple), do: %Postgrex.INET{address: ip_tuple, netmask: 32}

  defp to_inet({_, _, _, _, _, _, _, _} = ip_tuple),
    do: %Postgrex.INET{address: ip_tuple, netmask: 128}
end
