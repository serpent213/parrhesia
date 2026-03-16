defmodule Parrhesia.Sync.TLS do
  @moduledoc false

  @type tls_config :: %{
          mode: :required | :disabled,
          hostname: String.t(),
          pins: [%{type: :spki_sha256, value: String.t()}]
        }

  @spec websocket_options(tls_config()) :: keyword()
  def websocket_options(%{mode: :disabled}), do: [insecure: true]

  def websocket_options(%{mode: :required} = tls) do
    [
      ssl_options: transport_opts(tls)
    ]
  end

  @spec req_connect_options(tls_config()) :: keyword()
  def req_connect_options(%{mode: :disabled}), do: []

  def req_connect_options(%{mode: :required} = tls) do
    [
      transport_opts: transport_opts(tls)
    ]
  end

  def transport_opts(%{hostname: hostname, pins: pins}) do
    [
      verify: :verify_peer,
      cacerts: system_cacerts(),
      server_name_indication: String.to_charlist(hostname),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
    |> maybe_put_verify_fun(pins)
  end

  defp maybe_put_verify_fun(options, []), do: options

  defp maybe_put_verify_fun(options, pins) do
    Keyword.put(
      options,
      :verify_fun,
      {&verify_certificate/3, %{pins: MapSet.new(Enum.map(pins, & &1.value)), matched?: false}}
    )
  end

  defp verify_certificate(_cert, :valid_peer, %{matched?: true} = state), do: {:valid, state}
  defp verify_certificate(_cert, :valid_peer, _state), do: {:fail, :pin_mismatch}

  defp verify_certificate(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}

  defp verify_certificate(cert, _event, state) when is_binary(cert) do
    matched? = MapSet.member?(state.pins, spki_pin_from_verify(cert))
    {:valid, %{state | matched?: state.matched? or matched?}}
  rescue
    _error -> {:fail, :invalid_certificate}
  end

  defp verify_certificate({:OTPCertificate, _tbs, _sig_alg, _sig} = cert, _event, state) do
    matched? = MapSet.member?(state.pins, spki_pin_from_verify(cert))
    {:valid, %{state | matched?: state.matched? or matched?}}
  rescue
    _error -> {:fail, :invalid_certificate}
  end

  defp verify_certificate({:Certificate, _tbs, _sig_alg, _sig} = cert, _event, state) do
    matched? = MapSet.member?(state.pins, spki_pin_from_verify(cert))
    {:valid, %{state | matched?: state.matched? or matched?}}
  rescue
    _error -> {:fail, :invalid_certificate}
  end

  defp verify_certificate(_cert, _event, state), do: {:valid, state}

  defp spki_pin(cert_der) do
    cert = :public_key.pkix_decode_cert(cert_der, :plain)
    spki = cert |> elem(1) |> elem(7)

    :public_key.der_encode(:SubjectPublicKeyInfo, spki)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp spki_pin_from_verify(cert) when is_binary(cert), do: spki_pin(cert)

  defp spki_pin_from_verify({:OTPCertificate, _tbs, _sig_alg, _sig} = cert) do
    cert
    |> then(&:public_key.pkix_encode(:OTPCertificate, &1, :otp))
    |> spki_pin()
  end

  defp spki_pin_from_verify({:Certificate, _tbs, _sig_alg, _sig} = cert) do
    cert
    |> then(&:public_key.der_encode(:Certificate, &1))
    |> spki_pin()
  end

  defp spki_pin_from_verify(_cert) do
    raise(ArgumentError, "invalid certificate")
  end

  defp system_cacerts do
    if function_exported?(:public_key, :cacerts_get, 0) do
      :public_key.cacerts_get()
    else
      []
    end
  end
end
