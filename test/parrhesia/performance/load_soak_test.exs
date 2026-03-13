defmodule Parrhesia.Performance.LoadSoakTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Repo
  alias Parrhesia.Web.Connection

  @tag :performance
  test "fanout enqueue/drain stays within relaxed p95 budget" do
    :ok = Sandbox.checkout(Repo)

    {:ok, state} = Connection.init(subscription_index: nil, max_outbound_queue: 10_000)

    req_payload = JSON.encode!(["REQ", "sub-load", %{"kinds" => [1]}])

    assert {:push, _frames, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    durations =
      for idx <- 1..200 do
        event = %{
          "id" => "event-#{idx}",
          "pubkey" => String.duplicate("a", 64),
          "created_at" => System.system_time(:second),
          "kind" => 1,
          "tags" => [],
          "content" => "load",
          "sig" => String.duplicate("b", 128)
        }

        started_at = System.monotonic_time()

        assert {:ok, _queued_state} =
                 Connection.handle_info({:fanout_event, "sub-load", event}, subscribed_state)

        System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)
      end

    p95 = percentile(durations, 95)
    assert p95 < 25_000
  end

  defp percentile(values, percentile_rank) do
    sorted = Enum.sort(values)
    index = max(0, ceil(length(sorted) * percentile_rank / 100) - 1)
    Enum.at(sorted, index)
  end
end
