defmodule Parrhesia.Negentropy.MessageTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Negentropy.Message

  test "encodes and decodes mixed range messages" do
    first_id = <<1::size(256)>>
    second_id = <<2::size(256)>>

    boundary =
      Message.split_bound(%{created_at: 10, id: first_id}, %{created_at: 10, id: second_id})

    ranges = [
      %{upper_bound: boundary, mode: :fingerprint, payload: <<0::size(128)>>},
      %{upper_bound: {11, Message.zero_id()}, mode: :id_list, payload: [second_id]},
      %{upper_bound: :infinity, mode: :skip, payload: nil}
    ]

    assert {:ok, decoded_ranges} = ranges |> Message.encode() |> Message.decode()

    assert decoded_ranges ==
             Enum.reject(ranges, &(&1.mode == :skip and &1.upper_bound == :infinity))
  end

  test "rejects malformed bounds and payloads" do
    assert {:error, :invalid_message} = Message.decode(<<0x61, 0x00, 0x01, 0x02>>)
  end
end
