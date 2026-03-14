defmodule Parrhesia.Web.RelayInfo do
  @moduledoc """
  NIP-11 relay information document.
  """

  @spec document() :: map()
  def document do
    %{
      "name" => "Parrhesia",
      "description" => "Nostr/Marmot relay",
      "pubkey" => nil,
      "supported_nips" => supported_nips(),
      "software" => "https://git.teralink.net/self/parrhesia",
      "version" => Application.spec(:parrhesia, :vsn) |> to_string(),
      "limitation" => limitations()
    }
  end

  defp supported_nips do
    base = [1, 9, 11, 13, 17, 40, 42, 43, 44, 45, 50, 59, 62, 66, 70]

    with_negentropy =
      if negentropy_enabled?() do
        base ++ [77]
      else
        base
      end

    with_negentropy ++ [86, 98]
  end

  defp limitations do
    %{
      "max_message_length" => Parrhesia.Config.get([:limits, :max_frame_bytes], 1_048_576),
      "max_subscriptions" =>
        Parrhesia.Config.get([:limits, :max_subscriptions_per_connection], 32),
      "max_filters" => Parrhesia.Config.get([:limits, :max_filters_per_req], 16),
      "auth_required" => Parrhesia.Config.get([:policies, :auth_required_for_reads], false)
    }
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end
end
