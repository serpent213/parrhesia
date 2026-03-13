defmodule Parrhesia.Auth.Nip98 do
  @moduledoc """
  Minimal NIP-98 HTTP auth validation.
  """

  alias Parrhesia.Protocol.EventValidator

  @max_age_seconds 60

  @spec validate_authorization_header(String.t() | nil, String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def validate_authorization_header(nil, _method, _url), do: {:error, :missing_authorization}

  def validate_authorization_header("Nostr " <> encoded_event, method, url)
      when is_binary(method) and is_binary(url) do
    with {:ok, event_json} <- decode_base64(encoded_event),
         {:ok, event} <- Jason.decode(event_json),
         :ok <- validate_event_shape(event),
         :ok <- validate_http_binding(event, method, url) do
      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_authorization}
    end
  end

  def validate_authorization_header(_header, _method, _url), do: {:error, :invalid_authorization}

  defp decode_base64(encoded_event) do
    case Base.decode64(encoded_event) do
      {:ok, event_json} -> {:ok, event_json}
      :error -> Base.url_decode64(encoded_event, padding: false)
    end
  end

  defp validate_event_shape(event) when is_map(event) do
    with :ok <- EventValidator.validate(event),
         :ok <- validate_kind(event),
         :ok <- validate_fresh_created_at(event) do
      :ok
    else
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_event}
    end
  end

  defp validate_event_shape(_event), do: {:error, :invalid_event}

  defp validate_kind(%{"kind" => 27_235}), do: :ok
  defp validate_kind(_event), do: {:error, :invalid_event}

  defp validate_fresh_created_at(%{"created_at" => created_at}) when is_integer(created_at) do
    now = System.system_time(:second)

    if abs(now - created_at) <= @max_age_seconds do
      :ok
    else
      {:error, :stale_event}
    end
  end

  defp validate_fresh_created_at(_event), do: {:error, :invalid_event}

  defp validate_http_binding(event, method, url) do
    tags = Map.get(event, "tags", [])

    method_matches? =
      Enum.any?(tags, fn
        ["method", tagged_method | _rest] when is_binary(tagged_method) ->
          String.upcase(tagged_method) == String.upcase(method)

        _tag ->
          false
      end)

    url_matches? =
      Enum.any?(tags, fn
        ["u", tagged_url | _rest] when is_binary(tagged_url) -> tagged_url == url
        _tag -> false
      end)

    cond do
      not method_matches? -> {:error, :invalid_method_tag}
      not url_matches? -> {:error, :invalid_url_tag}
      true -> :ok
    end
  end
end
