defmodule Parrhesia.API.Identity do
  @moduledoc """
  Server-auth identity management.
  """

  alias Parrhesia.API.Auth

  @type identity_metadata :: %{
          pubkey: String.t(),
          source: :configured | :persisted | :generated | :imported
        }

  @spec get(keyword()) :: {:ok, identity_metadata()} | {:error, term()}
  def get(opts \\ []) do
    with {:ok, identity} <- fetch_existing_identity(opts) do
      {:ok, public_identity(identity)}
    end
  end

  @spec ensure(keyword()) :: {:ok, identity_metadata()} | {:error, term()}
  def ensure(opts \\ []) do
    with {:ok, identity} <- ensure_identity(opts) do
      {:ok, public_identity(identity)}
    end
  end

  @spec import(map(), keyword()) :: {:ok, identity_metadata()} | {:error, term()}
  def import(identity, opts \\ [])

  def import(identity, opts) when is_map(identity) do
    with {:ok, secret_key} <- fetch_secret_key(identity),
         {:ok, normalized_identity} <- build_identity(secret_key, :imported),
         :ok <- persist_identity(normalized_identity, opts) do
      {:ok, public_identity(normalized_identity)}
    end
  end

  def import(_identity, _opts), do: {:error, :invalid_identity}

  @spec rotate(keyword()) :: {:ok, identity_metadata()} | {:error, term()}
  def rotate(opts \\ []) do
    with :ok <- ensure_rotation_allowed(opts),
         {:ok, identity} <- generate_identity(:generated),
         :ok <- persist_identity(identity, opts) do
      {:ok, public_identity(identity)}
    end
  end

  @spec sign_event(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign_event(event, opts \\ [])

  def sign_event(event, opts) when is_map(event) and is_list(opts) do
    with :ok <- validate_signable_event(event),
         {:ok, identity} <- ensure_identity(opts),
         signed_event <- attach_signature(event, identity) do
      {:ok, signed_event}
    end
  end

  def sign_event(_event, _opts), do: {:error, :invalid_event}

  def default_path do
    Path.join([default_data_dir(), "server_identity.json"])
  end

  defp ensure_identity(opts) do
    case fetch_existing_identity(opts) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, :identity_not_found} ->
        with {:ok, identity} <- generate_identity(:generated),
             :ok <- persist_identity(identity, opts) do
          {:ok, identity}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_existing_identity(opts) do
    if configured_private_key = configured_private_key(opts) do
      build_identity(configured_private_key, :configured)
    else
      read_persisted_identity(opts)
    end
  end

  defp ensure_rotation_allowed(opts) do
    if configured_private_key(opts) do
      {:error, :configured_identity_cannot_rotate}
    else
      :ok
    end
  end

  defp validate_signable_event(event) do
    signable =
      is_integer(Map.get(event, "created_at")) and
        is_integer(Map.get(event, "kind")) and
        is_list(Map.get(event, "tags")) and
        is_binary(Map.get(event, "content", ""))

    if signable, do: :ok, else: {:error, :invalid_event}
  end

  defp attach_signature(event, identity) do
    unsigned_event =
      event
      |> Map.put("pubkey", identity.pubkey)
      |> Map.put("sig", String.duplicate("0", 128))

    event_id =
      unsigned_event
      |> Auth.compute_event_id()

    signature =
      event_id
      |> Base.decode16!(case: :lower)
      |> Secp256k1.schnorr_sign(identity.secret_key)
      |> Base.encode16(case: :lower)

    unsigned_event
    |> Map.put("id", event_id)
    |> Map.put("sig", signature)
  end

  defp read_persisted_identity(opts) do
    path = identity_path(opts)

    case File.read(path) do
      {:ok, payload} ->
        with {:ok, decoded} <- JSON.decode(payload),
             {:ok, secret_key} <- fetch_secret_key(decoded),
             {:ok, identity} <- build_identity(secret_key, :persisted) do
          {:ok, identity}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :identity_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_identity(identity, opts) do
    path = identity_path(opts)
    temp_path = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, JSON.encode!(persisted_identity(identity))),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  defp persisted_identity(identity) do
    %{
      "secret_key" => Base.encode16(identity.secret_key, case: :lower),
      "pubkey" => identity.pubkey
    }
  end

  defp generate_identity(source) do
    {secret_key, pubkey} = Secp256k1.keypair(:xonly)

    {:ok,
     %{
       secret_key: secret_key,
       pubkey: Base.encode16(pubkey, case: :lower),
       source: source
     }}
  rescue
    _error -> {:error, :identity_generation_failed}
  end

  defp build_identity(secret_key_hex, source) when is_binary(secret_key_hex) do
    with {:ok, secret_key} <- decode_secret_key(secret_key_hex),
         pubkey <- Secp256k1.pubkey(secret_key, :xonly) do
      {:ok,
       %{
         secret_key: secret_key,
         pubkey: Base.encode16(pubkey, case: :lower),
         source: source
       }}
    end
  rescue
    _error -> {:error, :invalid_secret_key}
  end

  defp decode_secret_key(secret_key_hex) when is_binary(secret_key_hex) do
    normalized = String.downcase(secret_key_hex)

    case Base.decode16(normalized, case: :lower) do
      {:ok, <<_::256>> = secret_key} -> {:ok, secret_key}
      _other -> {:error, :invalid_secret_key}
    end
  end

  defp fetch_secret_key(identity) when is_map(identity) do
    case Map.get(identity, :secret_key) || Map.get(identity, "secret_key") do
      secret_key when is_binary(secret_key) -> {:ok, secret_key}
      _other -> {:error, :invalid_identity}
    end
  end

  defp configured_private_key(opts) do
    opts[:private_key] || opts[:configured_private_key] || config_value(:private_key)
  end

  defp identity_path(opts) do
    opts[:path] || config_value(:path) || default_path()
  end

  defp public_identity(identity) do
    %{
      pubkey: identity.pubkey,
      source: identity.source
    }
  end

  defp config_value(key) do
    :parrhesia
    |> Application.get_env(:identity, [])
    |> Keyword.get(key)
  end

  defp default_data_dir do
    base_dir =
      System.get_env("XDG_DATA_HOME") ||
        Path.join(System.user_home!(), ".local/share")

    Path.join(base_dir, "parrhesia")
  end
end
