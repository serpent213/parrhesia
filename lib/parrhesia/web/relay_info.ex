defmodule Parrhesia.Web.RelayInfo do
  @moduledoc """
  NIP-11 relay information document.
  """

  alias Parrhesia.API.Identity
  alias Parrhesia.NIP43
  alias Parrhesia.Web.Listener

  @spec document(Listener.t()) :: map()
  def document(listener) do
    %{
      "name" => "Parrhesia",
      "description" => "Nostr/Marmot relay",
      "pubkey" => relay_pubkey(),
      "self" => relay_pubkey(),
      "supported_nips" => supported_nips(),
      "software" => "https://git.teralink.net/self/parrhesia",
      "version" => Application.spec(:parrhesia, :vsn) |> to_string(),
      "limitation" => limitations(listener)
    }
  end

  defp supported_nips do
    base = [1, 9, 11, 13, 17, 40, 42, 44, 45, 50, 59, 62, 70]

    with_nip43 =
      if NIP43.enabled?() do
        base ++ [43]
      else
        base
      end

    with_nip66 =
      if Parrhesia.NIP66.enabled?() do
        with_nip43 ++ [66]
      else
        with_nip43
      end

    with_negentropy =
      if negentropy_enabled?() do
        with_nip66 ++ [77]
      else
        with_nip66
      end

    with_negentropy ++ [86, 98]
  end

  defp limitations(listener) do
    %{
      "max_message_length" => Parrhesia.Config.get([:limits, :max_frame_bytes], 1_048_576),
      "max_subscriptions" =>
        Parrhesia.Config.get([:limits, :max_subscriptions_per_connection], 32),
      "max_filters" => Parrhesia.Config.get([:limits, :max_filters_per_req], 16),
      "max_limit" => Parrhesia.Config.get([:limits, :max_filter_limit], 500),
      "max_event_tags" => Parrhesia.Config.get([:limits, :max_tags_per_event], 256),
      "min_pow_difficulty" => Parrhesia.Config.get([:policies, :min_pow_difficulty], 0),
      "auth_required" => Listener.relay_auth_required?(listener),
      "payment_required" => false,
      "restricted_writes" => restricted_writes?(listener)
    }
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end

  defp relay_pubkey do
    case Identity.get() do
      {:ok, %{pubkey: pubkey}} -> pubkey
      {:error, _reason} -> nil
    end
  end

  defp restricted_writes?(listener) do
    listener.auth.nip42_required or
      (listener.baseline_acl.write != [] and
         Enum.any?(listener.baseline_acl.write, &(&1.action == :deny))) or
      Parrhesia.Config.get([:policies, :auth_required_for_writes], false) or
      Parrhesia.Config.get([:policies, :min_pow_difficulty], 0) > 0
  end
end
