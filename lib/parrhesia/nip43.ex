defmodule Parrhesia.NIP43 do
  @moduledoc false

  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Groups.Flow
  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter

  @join_request_kind 28_934
  @invite_request_kind 28_935
  @leave_request_kind 28_936
  @add_user_kind 8_000
  @remove_user_kind 8_001
  @membership_list_kind 13_534
  @claim_token_kind 31_943
  @default_invite_ttl_seconds 900

  @type publish_state ::
          :ok
          | %{action: :join, duplicate?: boolean(), message: String.t()}
          | %{action: :leave, duplicate?: boolean(), message: String.t()}

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    config(opts)
    |> Keyword.get(:enabled, true)
    |> Kernel.==(true)
  end

  @spec prepare_publish(map(), keyword()) :: {:ok, publish_state()} | {:error, term()}
  def prepare_publish(event, opts \\ []) when is_map(event) and is_list(opts) do
    if enabled?(opts) do
      prepare_enabled_publish(event, opts)
    else
      prepare_disabled_publish(event)
    end
  end

  @spec finalize_publish(map(), publish_state(), keyword()) :: :ok | {:ok, String.t()}
  def finalize_publish(event, publish_state, opts \\ [])

  def finalize_publish(event, :ok, _opts) when is_map(event) do
    case Map.get(event, "kind") do
      kind when kind in [@add_user_kind, @remove_user_kind, @membership_list_kind] ->
        Flow.handle_event(event)

      _other ->
        :ok
    end
  end

  def finalize_publish(event, %{action: :join, duplicate?: true, message: message}, _opts)
      when is_map(event) do
    {:ok, message}
  end

  def finalize_publish(event, %{action: :join, duplicate?: false, message: message}, opts)
      when is_map(event) do
    opts = Keyword.put_new(opts, :now, Map.get(event, "created_at"))
    :ok = Flow.handle_event(event)
    publish_membership_events(Map.get(event, "pubkey"), :add, opts)
    {:ok, message}
  end

  def finalize_publish(event, %{action: :leave, duplicate?: true, message: message}, _opts)
      when is_map(event) do
    {:ok, message}
  end

  def finalize_publish(event, %{action: :leave, duplicate?: false, message: message}, opts)
      when is_map(event) do
    opts = Keyword.put_new(opts, :now, Map.get(event, "created_at"))
    :ok = Flow.handle_event(event)
    publish_membership_events(Map.get(event, "pubkey"), :remove, opts)
    {:ok, message}
  end

  @spec dynamic_events([map()], keyword()) :: [map()]
  def dynamic_events(filters, opts \\ []) when is_list(filters) and is_list(opts) do
    if enabled?(opts) and requests_invite?(filters) do
      filters
      |> build_invite_event(opts)
      |> maybe_wrap_event()
    else
      []
    end
  end

  @spec dynamic_count([map()], keyword()) :: non_neg_integer()
  def dynamic_count(filters, opts \\ []) do
    filters
    |> dynamic_events(opts)
    |> length()
  end

  defp prepare_enabled_publish(%{"kind" => @join_request_kind, "pubkey" => pubkey} = event, opts)
       when is_binary(pubkey) do
    with {:ok, _claim} <- validate_claim_from_event(event),
         {:ok, membership} <- Flow.get_membership(pubkey) do
      if membership_active?(membership) do
        {:ok,
         %{
           action: :join,
           duplicate?: true,
           message: "duplicate: you are already a member of this relay."
         }}
      else
        {:ok,
         %{
           action: :join,
           duplicate?: false,
           message: "info: welcome to #{relay_url(opts)}!"
         }}
      end
    end
  end

  defp prepare_enabled_publish(%{"kind" => @leave_request_kind, "pubkey" => pubkey}, _opts)
       when is_binary(pubkey) do
    with {:ok, membership} <- Flow.get_membership(pubkey) do
      if membership_active?(membership) do
        {:ok, %{action: :leave, duplicate?: false, message: "info: membership revoked."}}
      else
        {:ok,
         %{
           action: :leave,
           duplicate?: true,
           message: "duplicate: you are not a member of this relay."
         }}
      end
    end
  end

  defp prepare_enabled_publish(%{"kind" => @invite_request_kind}, _opts) do
    {:error, "restricted: kind 28935 invite claims are generated via REQ"}
  end

  defp prepare_enabled_publish(%{"kind" => kind, "pubkey" => pubkey}, _opts)
       when kind in [@add_user_kind, @remove_user_kind, @membership_list_kind] and
              is_binary(pubkey) do
    case relay_pubkey() do
      {:ok, ^pubkey} -> {:ok, :ok}
      {:ok, _other} -> {:error, "restricted: relay access metadata must be relay-signed"}
      {:error, _reason} -> {:error, "error: relay identity unavailable"}
    end
  end

  defp prepare_enabled_publish(_event, _opts), do: {:ok, :ok}

  defp prepare_disabled_publish(%{"kind" => kind})
       when kind in [
              @join_request_kind,
              @invite_request_kind,
              @leave_request_kind,
              @add_user_kind,
              @remove_user_kind,
              @membership_list_kind
            ] do
    {:error, "blocked: NIP-43 relay access requests are disabled"}
  end

  defp prepare_disabled_publish(_event), do: {:ok, :ok}

  defp build_invite_event(filters, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    identity_opts = identity_opts(opts)

    with {:ok, claim} <- issue_claim(now, opts),
         {:ok, signed_event} <-
           %{
             "created_at" => now,
             "kind" => @invite_request_kind,
             "tags" => [["-"], ["claim", claim]],
             "content" => ""
           }
           |> Identity.sign_event(identity_opts),
         true <- Filter.matches_any?(signed_event, filters) do
      {:ok, signed_event}
    else
      _other -> :error
    end
  end

  defp maybe_wrap_event({:ok, event}), do: [event]
  defp maybe_wrap_event(_other), do: []

  defp requests_invite?(filters) do
    Enum.any?(filters, fn filter ->
      case Map.get(filter, "kinds") do
        kinds when is_list(kinds) -> @invite_request_kind in kinds
        _other -> false
      end
    end)
  end

  defp issue_claim(now, opts) do
    ttl_seconds =
      config(opts)
      |> Keyword.get(:invite_ttl_seconds, @default_invite_ttl_seconds)
      |> normalize_positive_integer(@default_invite_ttl_seconds)

    identity_opts = identity_opts(opts)

    token_event = %{
      "created_at" => now,
      "kind" => @claim_token_kind,
      "tags" => [["exp", Integer.to_string(now + ttl_seconds)]],
      "content" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }

    with {:ok, signed_token} <- Identity.sign_event(token_event, identity_opts) do
      signed_token
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)
      |> then(&{:ok, &1})
    end
  end

  defp validate_claim_from_event(event) do
    claim =
      event
      |> Map.get("tags", [])
      |> Enum.find_value(fn
        ["claim", value | _rest] when is_binary(value) and value != "" -> value
        _tag -> nil
      end)

    case claim do
      nil -> {:error, "restricted: that is an invalid invite code."}
      value -> validate_claim(value)
    end
  end

  defp validate_claim(claim) when is_binary(claim) do
    with {:ok, payload} <- Base.url_decode64(claim, padding: false),
         {:ok, decoded} <- JSON.decode(payload),
         :ok <- Protocol.validate_event(decoded),
         :ok <- validate_claim_token(decoded) do
      {:ok, decoded}
    else
      {:error, :expired_claim} ->
        {:error, "restricted: that invite code is expired."}

      _other ->
        {:error, "restricted: that is an invalid invite code."}
    end
  end

  defp validate_claim(_claim), do: {:error, "restricted: that is an invalid invite code."}

  defp validate_claim_token(%{
         "kind" => @claim_token_kind,
         "pubkey" => pubkey,
         "tags" => tags
       }) do
    with {:ok, relay_pubkey} <- relay_pubkey(),
         true <- pubkey == relay_pubkey,
         {:ok, expires_at} <- fetch_expiration(tags),
         true <- expires_at >= System.system_time(:second) do
      :ok
    else
      false -> {:error, :invalid_claim}
      {:error, _reason} -> {:error, :invalid_claim}
    end
  end

  defp validate_claim_token(_event), do: {:error, :invalid_claim}

  defp fetch_expiration(tags) when is_list(tags) do
    case Enum.find(tags, &match?(["exp", _value | _rest], &1)) do
      ["exp", value | _rest] ->
        parse_expiration(value)

      _other ->
        {:error, :invalid_claim}
    end
  end

  defp parse_expiration(value) when is_binary(value) do
    case Integer.parse(value) do
      {expires_at, ""} when expires_at > 0 -> validate_expiration(expires_at)
      _other -> {:error, :invalid_claim}
    end
  end

  defp parse_expiration(_value), do: {:error, :invalid_claim}

  defp validate_expiration(expires_at) when is_integer(expires_at) do
    if expires_at >= System.system_time(:second) do
      {:ok, expires_at}
    else
      {:error, :expired_claim}
    end
  end

  defp validate_expiration(_expires_at), do: {:error, :expired_claim}

  defp publish_membership_events(member_pubkey, action, opts) when is_binary(member_pubkey) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    identity_opts = identity_opts(opts)
    context = Keyword.get(opts, :context, %RequestContext{})

    action
    |> build_membership_delta_event(member_pubkey, now)
    |> sign_and_publish(context, identity_opts)

    current_membership_snapshot(now)
    |> sign_and_publish(context, identity_opts)

    :ok
  end

  defp build_membership_delta_event(:add, member_pubkey, now) do
    %{
      "created_at" => now,
      "kind" => @add_user_kind,
      "tags" => [["-"], ["p", member_pubkey]],
      "content" => ""
    }
  end

  defp build_membership_delta_event(:remove, member_pubkey, now) do
    %{
      "created_at" => now,
      "kind" => @remove_user_kind,
      "tags" => [["-"], ["p", member_pubkey]],
      "content" => ""
    }
  end

  defp current_membership_snapshot(now) do
    tags =
      case Flow.list_memberships() do
        {:ok, memberships} ->
          [["-"] | Enum.map(memberships, &["member", &1.pubkey])]

        {:error, _reason} ->
          [["-"]]
      end

    %{
      "created_at" => now,
      "kind" => @membership_list_kind,
      "tags" => tags,
      "content" => ""
    }
  end

  defp sign_and_publish(unsigned_event, context, identity_opts) do
    with {:ok, signed_event} <- Identity.sign_event(unsigned_event, identity_opts),
         {:ok, %{accepted: true}} <- Events.publish(signed_event, context: context) do
      :ok
    else
      _other -> :ok
    end
  end

  defp membership_active?(nil), do: false
  defp membership_active?(%{role: "member"}), do: true
  defp membership_active?(_membership), do: false

  defp relay_pubkey do
    case Identity.get() do
      {:ok, %{pubkey: pubkey}} when is_binary(pubkey) -> {:ok, pubkey}
      {:error, reason} -> {:error, reason}
    end
  end

  defp relay_url(opts) do
    Keyword.get(opts, :relay_url, Application.get_env(:parrhesia, :relay_url))
  end

  defp identity_opts(opts) do
    opts
    |> Keyword.take([:path, :private_key, :configured_private_key])
  end

  defp config(opts) do
    case Keyword.get(opts, :config) do
      config when is_list(config) -> config
      _other -> Application.get_env(:parrhesia, :nip43, [])
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default
end
