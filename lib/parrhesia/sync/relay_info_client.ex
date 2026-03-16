defmodule Parrhesia.Sync.RelayInfoClient do
  @moduledoc false

  alias Parrhesia.Sync.TLS

  @spec verify_remote_identity(map(), keyword()) :: :ok | {:error, term()}
  def verify_remote_identity(server, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/2)

    with {:ok, response} <- request_fun.(relay_info_url(server.url), request_opts(server)),
         {:ok, pubkey} <- extract_pubkey(response) do
      if pubkey == server.auth_pubkey do
        :ok
      else
        {:error, :remote_identity_mismatch}
      end
    end
  end

  defp default_request(url, opts) do
    case Req.get(
           url: url,
           headers: [{"accept", "application/nostr+json"}],
           decode_body: false,
           connect_options: opts
         ) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_pubkey(%Req.Response{status: 200, body: body}) when is_binary(body) do
    with {:ok, payload} <- JSON.decode(body),
         pubkey when is_binary(pubkey) and pubkey != "" <- Map.get(payload, "pubkey") do
      {:ok, String.downcase(pubkey)}
    else
      nil -> {:error, :missing_remote_identity}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :missing_remote_identity}
    end
  end

  defp extract_pubkey(%Req.Response{status: status}),
    do: {:error, {:relay_info_request_failed, status}}

  defp extract_pubkey(_response), do: {:error, :invalid_relay_info}

  defp request_opts(%{tls: %{mode: :disabled}}), do: []
  defp request_opts(%{tls: tls}), do: TLS.req_connect_options(tls)

  defp relay_info_url(relay_url) do
    relay_url
    |> URI.parse()
    |> Map.update!(:scheme, fn
      "wss" -> "https"
      "ws" -> "http"
    end)
    |> URI.to_string()
  end
end
