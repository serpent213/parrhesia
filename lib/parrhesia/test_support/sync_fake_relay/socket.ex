defmodule Parrhesia.TestSupport.SyncFakeRelay.Socket do
  @moduledoc false

  @behaviour WebSock

  alias Parrhesia.TestSupport.SyncFakeRelay.Server

  def init(state), do: {:ok, Map.put(state, :authenticated?, false)}

  def handle_in({payload, [opcode: :text]}, state) do
    case JSON.decode(payload) do
      {:ok, ["REQ", subscription_id | _filters]} ->
        maybe_authorize_req(state, subscription_id)

      {:ok, ["AUTH", auth_event]} when is_map(auth_event) ->
        handle_auth(auth_event, state)

      {:ok, ["CLOSE", subscription_id]} ->
        Server.unregister_subscription(state.server, self(), subscription_id)

        {:push, {:text, JSON.encode!(["CLOSED", subscription_id, "error: subscription closed"])},
         state}

      _other ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  def handle_info({:sync_fake_relay_event, subscription_id, event}, state) do
    {:push, {:text, JSON.encode!(["EVENT", subscription_id, event])}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, state) do
    Enum.each(Map.get(state, :subscriptions, []), fn subscription_id ->
      Server.unregister_subscription(state.server, self(), subscription_id)
    end)

    :ok
  end

  defp maybe_authorize_req(%{authenticated?: true} = state, subscription_id) do
    Server.register_subscription(state.server, self(), subscription_id)

    frames =
      Server.initial_events(state.server)
      |> Enum.map(fn event -> {:text, JSON.encode!(["EVENT", subscription_id, event])} end)
      |> Kernel.++([{:text, JSON.encode!(["EOSE", subscription_id])}])

    next_state =
      state
      |> Map.update(:subscriptions, [subscription_id], &[subscription_id | &1])

    {:push, frames, next_state}
  end

  defp maybe_authorize_req(state, subscription_id) do
    challenge = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    next_state =
      state
      |> Map.put(:challenge, challenge)
      |> Map.put(:pending_subscription_id, subscription_id)

    {:push,
     [
       {:text, JSON.encode!(["AUTH", challenge])},
       {:text,
        JSON.encode!(["CLOSED", subscription_id, "auth-required: sync access requires AUTH"])}
     ], next_state}
  end

  defp handle_auth(auth_event, state) do
    challenge_ok? = has_tag?(auth_event, "challenge", state.challenge)
    relay_ok? = has_tag?(auth_event, "relay", state.relay_url)
    pubkey_ok? = Map.get(auth_event, "pubkey") == Server.expected_client_pubkey(state.server)

    if challenge_ok? and relay_ok? and pubkey_ok? do
      accepted_state = %{state | authenticated?: true}
      ok_frame = ["OK", Map.get(auth_event, "id"), true, "ok: auth accepted"]

      if subscription_id = Map.get(accepted_state, :pending_subscription_id) do
        next_state =
          accepted_state
          |> Map.delete(:pending_subscription_id)
          |> Map.update(:subscriptions, [subscription_id], &[subscription_id | &1])

        Server.register_subscription(state.server, self(), subscription_id)

        {:push,
         [{:text, JSON.encode!(ok_frame)} | auth_success_frames(accepted_state, subscription_id)],
         next_state}
      else
        {:push, {:text, JSON.encode!(ok_frame)}, accepted_state}
      end
    else
      {:push,
       {:text, JSON.encode!(["OK", Map.get(auth_event, "id"), false, "invalid: auth rejected"])},
       state}
    end
  end

  defp auth_success_frames(state, subscription_id) do
    Server.initial_events(state.server)
    |> Enum.map(fn event -> {:text, JSON.encode!(["EVENT", subscription_id, event])} end)
    |> Kernel.++([{:text, JSON.encode!(["EOSE", subscription_id])}])
  end

  defp has_tag?(event, name, expected_value) do
    Enum.any?(Map.get(event, "tags", []), fn
      [^name, ^expected_value | _rest] -> true
      _other -> false
    end)
  end
end
