defmodule Parrhesia.API.Stream do
  @moduledoc """
  In-process subscription API with relay-equivalent catch-up and live fanout semantics.
  """

  alias Parrhesia.API.Events
  alias Parrhesia.API.RequestContext
  alias Parrhesia.API.Stream.Subscription
  alias Parrhesia.Policy.EventPolicy
  alias Parrhesia.Protocol.Filter

  @spec subscribe(pid(), String.t(), [map()], keyword()) :: {:ok, reference()} | {:error, term()}
  def subscribe(subscriber, subscription_id, filters, opts \\ [])

  def subscribe(subscriber, subscription_id, filters, opts)
      when is_pid(subscriber) and is_binary(subscription_id) and is_list(filters) and
             is_list(opts) do
    with {:ok, context} <- fetch_context(opts),
         :ok <- Filter.validate_filters(filters),
         :ok <-
           EventPolicy.authorize_read(
             filters,
             context.authenticated_pubkeys,
             stream_context(context, subscription_id)
           ) do
      ref = make_ref()

      case DynamicSupervisor.start_child(
             Parrhesia.API.Stream.Supervisor,
             {Subscription,
              ref: ref, subscriber: subscriber, subscription_id: subscription_id, filters: filters}
           ) do
        {:ok, pid} ->
          finalize_subscription(pid, ref, filters, stream_context(context, subscription_id))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def subscribe(_subscriber, _subscription_id, _filters, _opts),
    do: {:error, :invalid_subscription}

  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) when is_reference(ref) do
    case Registry.lookup(Parrhesia.API.Stream.Registry, ref) do
      [{pid, _value}] ->
        try do
          :ok = GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end

        :ok

      [] ->
        :ok
    end
  end

  def unsubscribe(_ref), do: :ok

  defp fetch_context(opts) do
    case Keyword.get(opts, :context) do
      %RequestContext{} = context -> {:ok, context}
      _other -> {:error, :invalid_context}
    end
  end

  defp finalize_subscription(pid, ref, filters, context) do
    with {:ok, initial_events} <-
           Events.query(filters,
             context: context,
             validate_filters?: false,
             authorize_read?: false
           ),
         :ok <- Subscription.deliver_initial(pid, initial_events) do
      {:ok, ref}
    else
      {:error, reason} ->
        _ = safe_stop_subscription(pid)
        {:error, reason}
    end
  end

  defp safe_stop_subscription(pid) do
    GenServer.stop(pid, :shutdown)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stream_context(%RequestContext{} = context, subscription_id) do
    %RequestContext{context | subscription_id: subscription_id}
  end
end
