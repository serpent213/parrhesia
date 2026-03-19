defmodule Parrhesia.TestSupport.TLSCerts do
  @moduledoc false

  @spec create_ca!(String.t(), String.t()) :: map()
  def create_ca!(dir, name) do
    keyfile = Path.join(dir, "#{name}-ca.key.pem")
    certfile = Path.join(dir, "#{name}-ca.cert.pem")

    openssl!([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-sha256",
      "-days",
      "2",
      "-subj",
      "/CN=#{name} Test CA",
      "-keyout",
      keyfile,
      "-out",
      certfile
    ])

    %{keyfile: keyfile, certfile: certfile}
  end

  @spec issue_server_cert!(String.t(), map(), String.t()) :: map()
  def issue_server_cert!(dir, ca, name) do
    issue_cert!(
      dir,
      ca,
      name,
      "localhost",
      ["DNS:localhost", "IP:127.0.0.1"],
      "serverAuth"
    )
  end

  @spec issue_client_cert!(String.t(), map(), String.t()) :: map()
  def issue_client_cert!(dir, ca, name) do
    issue_cert!(dir, ca, name, name, [], "clientAuth")
  end

  @spec spki_pin!(String.t()) :: String.t()
  def spki_pin!(certfile) do
    certfile
    |> der_cert!()
    |> spki_pin()
  end

  @spec cert_sha256!(String.t()) :: String.t()
  def cert_sha256!(certfile) do
    certfile
    |> der_cert!()
    |> then(&Base.encode64(:crypto.hash(:sha256, &1)))
  end

  defp issue_cert!(dir, ca, name, common_name, san_entries, extended_key_usage) do
    keyfile = Path.join(dir, "#{name}.key.pem")
    csrfile = Path.join(dir, "#{name}.csr.pem")
    certfile = Path.join(dir, "#{name}.cert.pem")
    extfile = Path.join(dir, "#{name}.ext.cnf")

    openssl!([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=#{common_name}",
      "-keyout",
      keyfile,
      "-out",
      csrfile
    ])

    File.write!(extfile, extension_config(san_entries, extended_key_usage))

    openssl!([
      "x509",
      "-req",
      "-in",
      csrfile,
      "-CA",
      ca.certfile,
      "-CAkey",
      ca.keyfile,
      "-CAcreateserial",
      "-out",
      certfile,
      "-days",
      "2",
      "-sha256",
      "-extfile",
      extfile,
      "-extensions",
      "v3_req"
    ])

    %{keyfile: keyfile, certfile: certfile}
  end

  defp extension_config(san_entries, extended_key_usage) do
    san_block =
      case san_entries do
        [] -> ""
        entries -> "subjectAltName = #{Enum.join(entries, ",")}\n"
      end

    """
    [v3_req]
    basicConstraints = CA:FALSE
    keyUsage = digitalSignature,keyEncipherment
    extendedKeyUsage = #{extended_key_usage}
    #{san_block}
    """
  end

  defp der_cert!(certfile) do
    certfile
    |> File.read!()
    |> :public_key.pem_decode()
    |> List.first()
    |> elem(1)
  end

  defp spki_pin(cert_der) do
    cert = :public_key.pkix_decode_cert(cert_der, :plain)
    spki = cert |> elem(1) |> elem(7)

    :public_key.der_encode(:SubjectPublicKeyInfo, spki)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp openssl!(args) do
    case System.cmd(openssl_executable!(), args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "openssl failed with status #{status}: #{output}"
    end
  end

  defp openssl_executable! do
    case System.find_executable("openssl") do
      nil -> raise "openssl executable not found in PATH"
      path -> path
    end
  end
end
