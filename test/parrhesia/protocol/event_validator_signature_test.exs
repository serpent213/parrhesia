defmodule Parrhesia.Protocol.EventValidatorSignatureTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Protocol.EventValidator

  test "accepts valid Schnorr signatures when verification is enabled" do
    previous_features = Application.get_env(:parrhesia, :features, [])

    Application.put_env(
      :parrhesia,
      :features,
      Keyword.put(previous_features, :verify_event_signatures, true)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :features, previous_features)
    end)

    event = signed_event()

    assert :ok = EventValidator.validate(event)
  end

  test "rejects invalid Schnorr signatures when verification is enabled" do
    previous_features = Application.get_env(:parrhesia, :features, [])

    Application.put_env(
      :parrhesia,
      :features,
      Keyword.put(previous_features, :verify_event_signatures, true)
    )

    on_exit(fn ->
      Application.put_env(:parrhesia, :features, previous_features)
    end)

    event =
      signed_event()
      |> Map.put("sig", String.duplicate("0", 128))

    assert {:error, :invalid_signature} = EventValidator.validate(event)
  end

  defp signed_event do
    {seckey, pubkey} = Secp256k1.keypair(:xonly)

    event = %{
      "pubkey" => Base.encode16(pubkey, case: :lower),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [["e", String.duplicate("a", 64), "wss://relay.example", "reply"]],
      "content" => "signed"
    }

    id = EventValidator.compute_id(event)
    {:ok, id_bin} = Base.decode16(id, case: :lower)
    sig = Secp256k1.schnorr_sign(id_bin, seckey)

    event
    |> Map.put("id", id)
    |> Map.put("sig", Base.encode16(sig, case: :lower))
  end
end
