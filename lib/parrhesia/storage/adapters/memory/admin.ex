defmodule Parrhesia.Storage.Adapters.Memory.Admin do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.Admin`.
  """

  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.Admin

  @impl true
  def execute(_context, method, _params) do
    case method do
      method when method in [:ping, "ping"] -> {:ok, %{"status" => "ok"}}
      _other -> {:error, {:unsupported_method, normalize_method(method)}}
    end
  end

  @impl true
  def append_audit_log(_context, audit_entry) when is_map(audit_entry) do
    Store.update(fn state -> update_in(state.audit_logs, &[audit_entry | &1]) end)
    :ok
  end

  def append_audit_log(_context, _audit_entry), do: {:error, :invalid_audit_entry}

  @impl true
  def list_audit_logs(_context, _opts) do
    {:ok, Store.get(fn state -> Enum.reverse(state.audit_logs) end)}
  end

  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method(method), do: inspect(method)
end
