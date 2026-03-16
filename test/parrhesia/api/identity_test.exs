defmodule Parrhesia.API.IdentityTest do
  use ExUnit.Case, async: false

  alias Parrhesia.API.Auth
  alias Parrhesia.API.Identity

  test "ensure generates and persists a server identity" do
    path = unique_identity_path()

    assert {:error, :identity_not_found} = Identity.get(path: path)

    assert {:ok, %{pubkey: pubkey, source: :generated}} = Identity.ensure(path: path)
    assert File.exists?(path)

    assert {:ok, %{pubkey: ^pubkey, source: :persisted}} = Identity.get(path: path)
    assert {:ok, %{pubkey: ^pubkey, source: :persisted}} = Identity.ensure(path: path)
  end

  test "import persists an explicit secret key and sign_event uses it" do
    path = unique_identity_path()
    secret_key = String.duplicate("1", 64)

    expected_pubkey =
      secret_key
      |> Base.decode16!(case: :lower)
      |> Secp256k1.pubkey(:xonly)
      |> Base.encode16(case: :lower)

    assert {:ok, %{pubkey: ^expected_pubkey, source: :imported}} =
             Identity.import(%{secret_key: secret_key}, path: path)

    assert {:ok, %{pubkey: ^expected_pubkey, source: :persisted}} = Identity.get(path: path)

    event = %{
      "created_at" => System.system_time(:second),
      "kind" => 22_242,
      "tags" => [],
      "content" => "identity-auth"
    }

    assert {:ok, signed_event} = Identity.sign_event(event, path: path)
    assert signed_event["pubkey"] == expected_pubkey
    assert signed_event["id"] == Auth.compute_event_id(signed_event)

    signature = Base.decode16!(signed_event["sig"], case: :lower)
    event_id = Base.decode16!(signed_event["id"], case: :lower)
    pubkey = Base.decode16!(signed_event["pubkey"], case: :lower)

    assert Secp256k1.schnorr_valid?(signature, event_id, pubkey)
  end

  test "rotate rejects configured identities and sign_event validates shape" do
    path = unique_identity_path()
    secret_key = String.duplicate("2", 64)

    assert {:error, :configured_identity_cannot_rotate} =
             Identity.rotate(path: path, configured_private_key: secret_key)

    assert {:error, :invalid_event} = Identity.sign_event(%{"kind" => 1}, path: path)
  end

  defp unique_identity_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "parrhesia_identity_#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn ->
      _ = File.rm(path)
    end)

    path
  end
end
