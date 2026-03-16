defmodule Parrhesia.Web.RemoteIp do
  @moduledoc false

  import Bitwise

  alias Parrhesia.Web.Listener

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if trusted_proxy?(conn) and honor_x_forwarded_for?(conn) do
      case forwarded_ip(conn) do
        nil -> conn
        forwarded_ip -> %{conn | remote_ip: forwarded_ip}
      end
    else
      conn
    end
  end

  defp forwarded_ip(conn) do
    conn
    |> x_forwarded_for_ip()
    |> fallback_forwarded_ip(conn)
    |> fallback_real_ip(conn)
  end

  defp x_forwarded_for_ip(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> List.first()
    |> parse_x_forwarded_for()
  end

  defp fallback_forwarded_ip(nil, conn) do
    conn
    |> Plug.Conn.get_req_header("forwarded")
    |> List.first()
    |> parse_forwarded_header()
  end

  defp fallback_forwarded_ip(ip, _conn), do: ip

  defp fallback_real_ip(nil, conn) do
    conn
    |> Plug.Conn.get_req_header("x-real-ip")
    |> List.first()
    |> parse_ip_string()
  end

  defp fallback_real_ip(ip, _conn), do: ip

  defp trusted_proxy?(conn) do
    Enum.any?(trusted_proxies(conn), &ip_in_cidr?(conn.remote_ip, &1))
  end

  defp trusted_proxies(conn) do
    listener = Listener.from_conn(conn)

    case Listener.trusted_proxies(listener) do
      [] ->
        :parrhesia
        |> Application.get_env(:trusted_proxies, [])
        |> Enum.filter(&is_binary/1)

      trusted_proxies ->
        trusted_proxies
    end
  end

  defp honor_x_forwarded_for?(conn) do
    listener = Listener.from_conn(conn)
    listener.proxy.honor_x_forwarded_for
  end

  defp parse_x_forwarded_for(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(&parse_ip_string/1)
  end

  defp parse_x_forwarded_for(_value), do: nil

  defp parse_forwarded_header(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.find_value(fn part ->
      part
      |> String.split(";")
      |> Enum.find_value(&forwarded_for_segment/1)
    end)
  end

  defp parse_forwarded_header(_value), do: nil

  defp forwarded_for_segment(segment) do
    case String.split(segment, "=", parts: 2) do
      [key, ip] ->
        if String.downcase(String.trim(key)) == "for" do
          ip
          |> String.trim()
          |> String.trim("\"")
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> parse_ip_string()
        end

      _other ->
        nil
    end
  end

  defp parse_ip_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(":", parts: 2)
    |> List.first()
    |> then(fn ip ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, parsed_ip} -> parsed_ip
        _other -> nil
      end
    end)
  end

  defp parse_ip_string(_value), do: nil

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

      [address] ->
        case :inet.parse_address(String.to_charlist(address)) do
          {:ok, {_, _, _, _} = ip} -> {ip, 32}
          {:ok, {_, _, _, _, _, _, _, _} = ip} -> {ip, 128}
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
end
