defmodule Parrhesia.Web.TLS do
  @moduledoc false

  import Bitwise

  require Record

  Record.defrecordp(
    :otp_certificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @default_proxy_headers %{
    enabled: false,
    required: false,
    verify_header: "x-parrhesia-client-cert-verified",
    verified_values: ["1", "true", "success", "verified"],
    cert_sha256_header: "x-parrhesia-client-cert-sha256",
    spki_sha256_header: "x-parrhesia-client-spki-sha256",
    subject_header: "x-parrhesia-client-cert-subject"
  }

  @type pin :: %{
          type: :cert_sha256 | :spki_sha256,
          value: String.t()
        }

  @type config :: %{
          mode: :disabled | :server | :mutual | :proxy_terminated,
          certfile: String.t() | nil,
          keyfile: String.t() | nil,
          cacertfile: String.t() | nil,
          otp_app: atom() | nil,
          cipher_suite: :strong | :compatible | nil,
          client_pins: [pin()],
          proxy_headers: map()
        }

  @spec default_config() :: config()
  def default_config do
    %{
      mode: :disabled,
      certfile: nil,
      keyfile: nil,
      cacertfile: nil,
      otp_app: nil,
      cipher_suite: nil,
      client_pins: [],
      proxy_headers: @default_proxy_headers
    }
  end

  @spec normalize_config(map() | nil, atom()) :: config()
  def normalize_config(tls, scheme)

  def normalize_config(tls, scheme) when is_map(tls) do
    defaults =
      default_config()
      |> Map.put(:mode, default_mode(scheme))

    %{
      mode: normalize_mode(fetch_value(tls, :mode), defaults.mode),
      certfile: normalize_optional_string(fetch_value(tls, :certfile)),
      keyfile: normalize_optional_string(fetch_value(tls, :keyfile)),
      cacertfile: normalize_optional_string(fetch_value(tls, :cacertfile)),
      otp_app: normalize_optional_atom(fetch_value(tls, :otp_app)),
      cipher_suite: normalize_cipher_suite(fetch_value(tls, :cipher_suite)),
      client_pins: normalize_pins(fetch_value(tls, :client_pins)),
      proxy_headers: normalize_proxy_headers(fetch_value(tls, :proxy_headers))
    }
  end

  def normalize_config(_tls, scheme) do
    %{default_config() | mode: default_mode(scheme)}
  end

  @spec bandit_options(config()) :: keyword()
  def bandit_options(%{mode: mode}) when mode in [:disabled, :proxy_terminated], do: []

  def bandit_options(%{mode: mode} = tls) when mode in [:server, :mutual] do
    transport_options =
      transport_options(tls)
      |> Keyword.merge(mutual_tls_options(tls))
      |> configure_server_tls()

    [
      scheme: :https,
      thousand_island_options: [transport_options: transport_options]
    ]
  end

  @spec authorize_request(config(), Plug.Conn.t(), boolean()) ::
          {:ok, map() | nil} | {:error, atom()}
  def authorize_request(%{mode: :disabled}, _conn, _trusted_proxy?), do: {:ok, nil}

  def authorize_request(%{mode: :server}, conn, _trusted_proxy?) do
    {:ok, socket_identity(conn)}
  end

  def authorize_request(%{mode: :mutual} = tls, conn, _trusted_proxy?) do
    with %{} = identity <- socket_identity(conn),
         :ok <- verify_pins(identity, tls.client_pins, :client_certificate_pin_mismatch) do
      {:ok, identity}
    else
      nil -> {:error, :client_certificate_required}
      {:error, _reason} = error -> error
    end
  end

  def authorize_request(%{mode: :proxy_terminated} = tls, conn, trusted_proxy?) do
    proxy_headers = tls.proxy_headers

    if proxy_headers.enabled do
      authorize_proxy_identity(conn, proxy_headers, tls.client_pins, trusted_proxy?)
    else
      {:ok, nil}
    end
  end

  @spec request_scheme(config(), Plug.Conn.t(), boolean()) :: :http | :https
  def request_scheme(%{mode: :proxy_terminated}, conn, true) do
    case header_value(conn, "x-forwarded-proto") do
      "https" -> :https
      "http" -> :http
      _other -> conn.scheme
    end
  end

  def request_scheme(_tls, conn, _trusted_proxy?), do: conn.scheme

  @spec request_host(Plug.Conn.t(), boolean()) :: String.t()
  def request_host(conn, true) do
    case header_value(conn, "x-forwarded-host") do
      nil -> conn.host
      value -> String.split(value, ",", parts: 2) |> List.first() |> String.trim()
    end
  end

  def request_host(conn, false), do: conn.host

  @spec request_port(config(), Plug.Conn.t(), boolean(), :http | :https) :: non_neg_integer()
  def request_port(%{mode: :proxy_terminated}, conn, true, forwarded_scheme) do
    case header_value(conn, "x-forwarded-port") do
      nil -> default_port(forwarded_scheme)
      value -> parse_port(value, default_port(forwarded_scheme))
    end
  end

  def request_port(_tls, conn, _trusted_proxy?, _scheme), do: conn.port

  @spec trusted_proxy_request?(Plug.Conn.t(), [String.t()]) :: boolean()
  def trusted_proxy_request?(conn, trusted_cidrs) when is_list(trusted_cidrs) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: address} -> Enum.any?(trusted_cidrs, &ip_in_cidr?(address, &1))
      _other -> false
    end
  end

  def trusted_proxy_request?(_conn, _trusted_cidrs), do: false

  defp transport_options(tls) do
    []
    |> maybe_put_opt(:keyfile, tls.keyfile)
    |> maybe_put_opt(:certfile, tls.certfile)
    |> maybe_put_opt(:cacertfile, tls.cacertfile)
    |> maybe_put_opt(:otp_app, tls.otp_app)
    |> maybe_put_opt(:cipher_suite, tls.cipher_suite)
  end

  defp mutual_tls_options(%{mode: :mutual, cacertfile: nil}) do
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacerts: system_cacerts()
    ]
  end

  defp mutual_tls_options(%{mode: :mutual}) do
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true
    ]
  end

  defp mutual_tls_options(_tls), do: []

  defp configure_server_tls(options) do
    case Plug.SSL.configure(options) do
      {:ok, configured} -> configured
      {:error, message} -> raise ArgumentError, "invalid listener TLS config: #{message}"
    end
  end

  defp authorize_proxy_identity(conn, proxy_headers, pins, trusted_proxy?) do
    cond do
      not trusted_proxy? and proxy_headers.required ->
        {:error, :proxy_tls_identity_required}

      not trusted_proxy? ->
        {:ok, nil}

      true ->
        conn
        |> proxy_identity(proxy_headers)
        |> authorize_proxy_identity_value(proxy_headers.required, pins)
    end
  end

  defp authorize_proxy_identity_value(nil, true, _pins),
    do: {:error, :proxy_tls_identity_required}

  defp authorize_proxy_identity_value(nil, false, _pins), do: {:ok, nil}

  defp authorize_proxy_identity_value(%{verified?: false}, _required, _pins) do
    {:error, :proxy_tls_identity_unverified}
  end

  defp authorize_proxy_identity_value(identity, _required, pins) do
    case verify_pins(identity, pins, :proxy_tls_identity_pin_mismatch) do
      :ok -> {:ok, identity}
      {:error, _reason} = error -> error
    end
  end

  defp proxy_identity(conn, proxy_headers) do
    cert_sha256 = header_value(conn, proxy_headers.cert_sha256_header)
    spki_sha256 = header_value(conn, proxy_headers.spki_sha256_header)
    subject = header_value(conn, proxy_headers.subject_header)
    verified? = verified_header?(conn, proxy_headers)

    if cert_sha256 || spki_sha256 || subject do
      %{
        source: :proxy,
        verified?: verified?,
        cert_sha256: cert_sha256,
        spki_sha256: spki_sha256,
        subject: subject
      }
    end
  end

  defp verified_header?(conn, proxy_headers) do
    case header_value(conn, proxy_headers.verify_header) do
      nil ->
        false

      value ->
        normalized = String.downcase(String.trim(value))
        normalized in Enum.map(proxy_headers.verified_values, &String.downcase/1)
    end
  end

  defp socket_identity(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{ssl_cert: cert_der} when is_binary(cert_der) ->
        certificate_identity(cert_der, :socket)

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  defp certificate_identity(cert_der, source) do
    %{
      source: source,
      verified?: true,
      cert_sha256: Base.encode64(:crypto.hash(:sha256, cert_der)),
      spki_sha256: spki_pin(cert_der),
      subject: certificate_subject(cert_der)
    }
  end

  defp certificate_subject(cert_der) do
    cert = :public_key.pkix_decode_cert(cert_der, :otp)

    cert
    |> otp_certificate(:tbsCertificate)
    |> otp_tbs_certificate(:subject)
    |> inspect()
  end

  defp verify_pins(_identity, [], _reason), do: :ok

  defp verify_pins(identity, pins, reason) do
    if Enum.any?(pins, &pin_matches?(identity, &1)) do
      :ok
    else
      {:error, reason}
    end
  end

  defp pin_matches?(identity, %{type: :cert_sha256, value: value}) do
    identity.cert_sha256 == value
  end

  defp pin_matches?(identity, %{type: :spki_sha256, value: value}) do
    identity.spki_sha256 == value
  end

  defp spki_pin(cert_der) do
    cert = :public_key.pkix_decode_cert(cert_der, :plain)
    spki = cert |> elem(1) |> elem(7)

    :public_key.der_encode(:SubjectPublicKeyInfo, spki)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp header_value(conn, header) when is_binary(header) and header != "" do
    conn
    |> Plug.Conn.get_req_header(header)
    |> List.first()
  end

  defp header_value(_conn, _header), do: nil

  defp default_mode(:https), do: :server
  defp default_mode(_scheme), do: :disabled

  defp default_port(:https), do: 443
  defp default_port(_scheme), do: 80

  defp parse_port(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port >= 0 -> port
      _other -> default
    end
  end

  defp normalize_mode(:server, _default), do: :server
  defp normalize_mode("server", _default), do: :server
  defp normalize_mode(:mutual, _default), do: :mutual
  defp normalize_mode("mutual", _default), do: :mutual
  defp normalize_mode(:proxy_terminated, _default), do: :proxy_terminated
  defp normalize_mode("proxy_terminated", _default), do: :proxy_terminated
  defp normalize_mode(:disabled, _default), do: :disabled
  defp normalize_mode("disabled", _default), do: :disabled
  defp normalize_mode(_value, default), do: default

  defp normalize_cipher_suite(:strong), do: :strong
  defp normalize_cipher_suite("strong"), do: :strong
  defp normalize_cipher_suite(:compatible), do: :compatible
  defp normalize_cipher_suite("compatible"), do: :compatible
  defp normalize_cipher_suite(_value), do: nil

  defp normalize_proxy_headers(headers) when is_map(headers) do
    %{
      enabled: normalize_boolean(fetch_value(headers, :enabled), false),
      required: normalize_boolean(fetch_value(headers, :required), false),
      verify_header:
        normalize_optional_string(fetch_value(headers, :verify_header)) ||
          @default_proxy_headers.verify_header,
      verified_values:
        normalize_string_list(fetch_value(headers, :verified_values)) ++
          Enum.filter(
            @default_proxy_headers.verified_values,
            &(&1 not in normalize_string_list(fetch_value(headers, :verified_values)))
          ),
      cert_sha256_header:
        normalize_optional_string(fetch_value(headers, :cert_sha256_header)) ||
          @default_proxy_headers.cert_sha256_header,
      spki_sha256_header:
        normalize_optional_string(fetch_value(headers, :spki_sha256_header)) ||
          @default_proxy_headers.spki_sha256_header,
      subject_header:
        normalize_optional_string(fetch_value(headers, :subject_header)) ||
          @default_proxy_headers.subject_header
    }
  end

  defp normalize_proxy_headers(_headers), do: @default_proxy_headers

  defp normalize_pins(pins) when is_list(pins) do
    Enum.flat_map(pins, fn
      %{type: type, value: value} ->
        case normalize_pin(type, value) do
          nil -> []
          pin -> [pin]
        end

      %{"type" => type, "value" => value} ->
        case normalize_pin(type, value) do
          nil -> []
          pin -> [pin]
        end

      _other ->
        []
    end)
  end

  defp normalize_pins(_pins), do: []

  defp normalize_pin(type, value) do
    with normalized_type when normalized_type in [:cert_sha256, :spki_sha256] <-
           normalize_pin_type(type),
         normalized_value when is_binary(normalized_value) and normalized_value != "" <-
           normalize_optional_string(value) do
      %{type: normalized_type, value: normalized_value}
    else
      _other -> nil
    end
  end

  defp normalize_pin_type(:cert_sha256), do: :cert_sha256
  defp normalize_pin_type("cert_sha256"), do: :cert_sha256
  defp normalize_pin_type(:spki_sha256), do: :spki_sha256
  defp normalize_pin_type("spki_sha256"), do: :spki_sha256
  defp normalize_pin_type(_type), do: nil

  defp maybe_put_opt(options, _key, nil), do: options
  defp maybe_put_opt(options, key, value), do: Keyword.put(options, key, value)

  defp fetch_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_value), do: nil

  defp normalize_optional_atom(value) when is_atom(value), do: value
  defp normalize_optional_atom(_value), do: nil

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(nil, default), do: default
  defp normalize_boolean(_value, default), do: default

  defp normalize_string_list(values) when is_list(values) do
    Enum.filter(values, &(is_binary(&1) and &1 != ""))
  end

  defp normalize_string_list(_values), do: []

  defp system_cacerts do
    if function_exported?(:public_key, :cacerts_get, 0) do
      :public_key.cacerts_get()
    else
      []
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
