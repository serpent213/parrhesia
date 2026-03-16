defmodule Parrhesia.Web.Management do
  @moduledoc """
  HTTP management API (NIP-86 style) with NIP-98 auth validation.
  """

  import Plug.Conn

  alias Parrhesia.API.Admin
  alias Parrhesia.API.Auth

  @spec handle(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def handle(conn, opts \\ []) do
    full_url = full_request_url(conn)
    method = conn.method
    authorization = get_req_header(conn, "authorization") |> List.first()
    auth_required? = admin_auth_required?(opts)

    with {:ok, auth_context} <-
           maybe_validate_nip98(auth_required?, authorization, method, full_url),
         {:ok, payload} <- parse_payload(conn.body_params),
         {:ok, result} <- execute_method(payload),
         :ok <- append_audit_log(auth_context, payload, result) do
      send_json(conn, 200, %{"ok" => true, "result" => result})
    else
      {:error, :missing_authorization} ->
        send_json(conn, 401, %{"ok" => false, "error" => "auth-required"})

      {:error, :invalid_authorization} ->
        send_json(conn, 401, %{"ok" => false, "error" => "invalid-authorization"})

      {:error, :invalid_event} ->
        send_json(conn, 401, %{"ok" => false, "error" => "invalid-auth-event"})

      {:error, :stale_event} ->
        send_json(conn, 401, %{"ok" => false, "error" => "stale-auth-event"})

      {:error, :invalid_method_tag} ->
        send_json(conn, 401, %{"ok" => false, "error" => "auth-method-tag-mismatch"})

      {:error, :invalid_url_tag} ->
        send_json(conn, 401, %{"ok" => false, "error" => "auth-url-tag-mismatch"})

      {:error, :invalid_payload} ->
        send_json(conn, 400, %{"ok" => false, "error" => "invalid-payload"})

      {:error, reason} ->
        send_json(conn, 400, %{"ok" => false, "error" => inspect(reason)})
    end
  end

  defp maybe_validate_nip98(true, authorization, method, url) do
    Auth.validate_nip98(authorization, method, url)
  end

  defp maybe_validate_nip98(false, _authorization, _method, _url) do
    {:ok, %{pubkey: nil}}
  end

  defp parse_payload(%{"method" => method} = payload) when is_binary(method) do
    params = Map.get(payload, "params", %{})

    if is_map(params) do
      {:ok, %{method: method, params: params}}
    else
      {:error, :invalid_payload}
    end
  end

  defp parse_payload(_payload), do: {:error, :invalid_payload}

  defp execute_method(payload) do
    Admin.execute(payload.method, payload.params)
  end

  defp append_audit_log(auth_context, payload, result) do
    Parrhesia.Storage.admin().append_audit_log(%{}, %{
      method: payload.method,
      actor_pubkey: auth_context.pubkey,
      params: payload.params,
      result: normalize_result(result)
    })
  end

  defp normalize_result(result) when is_map(result), do: result
  defp normalize_result(result) when is_list(result), do: %{"list" => result}
  defp normalize_result(result), do: %{"value" => inspect(result)}

  defp send_json(conn, status, body) do
    encoded = JSON.encode!(body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, encoded)
  end

  defp full_request_url(conn) do
    scheme = Atom.to_string(conn.scheme)
    host = conn.host
    port = conn.port

    port_suffix =
      cond do
        conn.scheme == :http and port == 80 -> ""
        conn.scheme == :https and port == 443 -> ""
        true -> ":#{port}"
      end

    query_suffix = if conn.query_string == "", do: "", else: "?#{conn.query_string}"

    "#{scheme}://#{host}#{port_suffix}#{conn.request_path}#{query_suffix}"
  end

  defp admin_auth_required?(opts) do
    opts
    |> Keyword.get(:listener)
    |> case do
      %{auth: %{nip98_required_for_admin: value}} -> value
      _other -> true
    end
  end
end
