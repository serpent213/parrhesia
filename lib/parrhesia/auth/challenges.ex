defmodule Parrhesia.Auth.Challenges do
  @moduledoc """
  Connection-scoped NIP-42 challenge storage.
  """

  use GenServer

  @type challenge :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec issue(pid()) :: challenge()
  def issue(owner_pid), do: issue(__MODULE__, owner_pid)

  @spec issue(GenServer.server(), pid()) :: challenge()
  def issue(server, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:issue, owner_pid})
  end

  @spec current(pid()) :: challenge() | nil
  def current(owner_pid), do: current(__MODULE__, owner_pid)

  @spec current(GenServer.server(), pid()) :: challenge() | nil
  def current(server, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:current, owner_pid})
  end

  @spec valid?(pid(), challenge()) :: boolean()
  def valid?(owner_pid, challenge), do: valid?(__MODULE__, owner_pid, challenge)

  @spec valid?(GenServer.server(), pid(), challenge()) :: boolean()
  def valid?(server, owner_pid, challenge) when is_pid(owner_pid) and is_binary(challenge) do
    GenServer.call(server, {:valid?, owner_pid, challenge})
  end

  @spec clear(pid()) :: :ok
  def clear(owner_pid), do: clear(__MODULE__, owner_pid)

  @spec clear(GenServer.server(), pid()) :: :ok
  def clear(server, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:clear, owner_pid})
  end

  @impl true
  def init(:ok) do
    {:ok, %{entries: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:issue, owner_pid}, _from, state) do
    challenge = generate_challenge()

    state =
      state
      |> ensure_monitor(owner_pid)
      |> put_in([:entries, owner_pid], challenge)

    {:reply, challenge, state}
  end

  def handle_call({:current, owner_pid}, _from, state) do
    {:reply, Map.get(state.entries, owner_pid), state}
  end

  def handle_call({:valid?, owner_pid, challenge}, _from, state) do
    valid? =
      case Map.get(state.entries, owner_pid) do
        stored_challenge when is_binary(stored_challenge) ->
          Plug.Crypto.secure_compare(stored_challenge, challenge)

        _other ->
          false
      end

    {:reply, valid?, state}
  end

  def handle_call({:clear, owner_pid}, _from, state) do
    {:reply, :ok, remove_owner(state, owner_pid)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner_pid, _reason}, state) do
    case Map.get(state.monitors, owner_pid) do
      ^monitor_ref -> {:noreply, remove_owner(state, owner_pid)}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_monitor(state, owner_pid) do
    case Map.has_key?(state.monitors, owner_pid) do
      true -> state
      false -> put_in(state, [:monitors, owner_pid], Process.monitor(owner_pid))
    end
  end

  defp remove_owner(state, owner_pid) do
    {monitor_ref, monitors} = Map.pop(state.monitors, owner_pid)

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    state
    |> Map.put(:monitors, monitors)
    |> update_in([:entries], &Map.delete(&1, owner_pid))
  end

  defp generate_challenge do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
