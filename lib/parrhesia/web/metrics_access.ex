defmodule Parrhesia.Web.MetricsAccess do
  @moduledoc false

  import Plug.Conn
  import Bitwise

  @private_cidrs [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "::1/128",
    "fc00::/7",
    "fe80::/10"
  ]

  @spec allowed?(Plug.Conn.t()) :: boolean()
  def allowed?(conn) do
    if metrics_public?() do
      true
    else
      token_allowed?(conn) and network_allowed?(conn)
    end
  end

  defp token_allowed?(conn) do
    case configured_auth_token() do
      nil ->
        true

      token ->
        provided_token(conn) == token
    end
  end

  defp provided_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> normalize_authorization_header()
  end

  defp normalize_authorization_header("Bearer " <> token), do: token
  defp normalize_authorization_header(token) when is_binary(token), do: token
  defp normalize_authorization_header(_header), do: nil

  defp network_allowed?(conn) do
    remote_ip = conn.remote_ip

    cond do
      configured_allowed_cidrs() != [] ->
        Enum.any?(configured_allowed_cidrs(), &ip_in_cidr?(remote_ip, &1))

      metrics_private_networks_only?() ->
        Enum.any?(@private_cidrs, &ip_in_cidr?(remote_ip, &1))

      true ->
        true
    end
  end

  defp ip_in_cidr?(ip, cidr) do
    with {network, prefix_len} <- parse_cidr(cidr),
         {:ok, ip_size, ip_value} <- ip_to_int(ip),
         {:ok, network_size, network_value} <- ip_to_int(network),
         true <- ip_size == network_size,
         true <- prefix_len >= 0,
         true <- prefix_len <= ip_size do
      mask = network_mask(ip_size, prefix_len)
      (ip_value &&& mask) == (network_value &&& mask)
    else
      _other -> false
    end
  end

  defp parse_cidr(cidr) when is_binary(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [address, prefix_str] ->
        with {prefix_len, ""} <- Integer.parse(prefix_str),
             {:ok, ip} <- :inet.parse_address(String.to_charlist(address)) do
          {ip, prefix_len}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp parse_cidr(_cidr), do: :error

  defp ip_to_int({a, b, c, d}) do
    {:ok, 32, (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
  end

  defp ip_to_int({a, b, c, d, e, f, g, h}) do
    {:ok, 128,
     (a <<< 112) + (b <<< 96) + (c <<< 80) + (d <<< 64) + (e <<< 48) + (f <<< 32) + (g <<< 16) +
       h}
  end

  defp ip_to_int(_ip), do: :error

  defp network_mask(_size, 0), do: 0

  defp network_mask(size, prefix_len) do
    all_ones = (1 <<< size) - 1
    all_ones <<< (size - prefix_len)
  end

  defp configured_allowed_cidrs do
    :parrhesia
    |> Application.get_env(:metrics, [])
    |> Keyword.get(:allowed_cidrs, [])
    |> Enum.filter(&is_binary/1)
  end

  defp configured_auth_token do
    case :parrhesia |> Application.get_env(:metrics, []) |> Keyword.get(:auth_token) do
      token when is_binary(token) and token != "" -> token
      _other -> nil
    end
  end

  defp metrics_public? do
    :parrhesia
    |> Application.get_env(:metrics, [])
    |> Keyword.get(:public, false)
  end

  defp metrics_private_networks_only? do
    :parrhesia
    |> Application.get_env(:metrics, [])
    |> Keyword.get(:private_networks_only, true)
  end
end
