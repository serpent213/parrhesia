defmodule Parrhesia.Negentropy.EngineTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Negentropy.Engine
  alias Parrhesia.Negentropy.Message

  test "returns exact id list for small mismatched ranges" do
    server_items = [
      %{created_at: 10, id: <<1::size(256)>>},
      %{created_at: 11, id: <<2::size(256)>>}
    ]

    assert {:ok, response} = Engine.answer(server_items, Engine.initial_message([]))

    assert {:ok, [%{mode: :id_list, payload: ids, upper_bound: :infinity}]} =
             Message.decode(response)

    assert ids == Enum.map(server_items, & &1.id)
  end

  test "splits large mismatched fingerprint ranges" do
    client_items =
      Enum.map(1..4, fn idx ->
        %{created_at: 100 + idx, id: <<idx::size(256)>>}
      end)

    server_items =
      client_items ++ [%{created_at: 200, id: <<99::size(256)>>}]

    initial_message = Engine.initial_message(client_items, id_list_threshold: 1)

    assert {:ok, response} = Engine.answer(server_items, initial_message, id_list_threshold: 1)
    assert {:ok, ranges} = Message.decode(response)

    assert Enum.all?(ranges, &(&1.mode in [:fingerprint, :id_list]))
    assert length(ranges) >= 2
  end

  test "downgrades unsupported versions" do
    assert {:ok, <<0x61>>} = Engine.answer([], <<0x62>>)
  end
end
