defmodule Parrhesia.Auth.ChallengesTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Auth.Challenges

  test "issues, validates and clears connection-scoped challenges" do
    server = start_supervised!({Challenges, name: nil})

    challenge = Challenges.issue(server, self())
    assert is_binary(challenge)

    assert Challenges.current(server, self()) == challenge
    assert Challenges.valid?(server, self(), challenge)

    refute Challenges.valid?(server, self(), "wrong")
    refute Challenges.valid?(server, self(), challenge <> "x")

    assert :ok = Challenges.clear(server, self())
    assert Challenges.current(server, self()) == nil
  end
end
