defmodule Parrhesia.NIP66.Probe do
  @moduledoc false

  alias Parrhesia.Sync.Transport.WebSockexClient

  @type result :: %{
          checks: [atom()],
          metrics: map(),
          relay_info: map() | nil,
          relay_info_body: String.t() | nil
        }

  @spec probe(map(), keyword(), keyword()) :: {:ok, result()}
  def probe(target, opts \\ [], publish_opts \\ [])

  def probe(target, opts, _publish_opts) when is_map(target) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    checks = normalize_checks(Keyword.get(opts, :checks, [:open, :read, :nip11]))

    initial = %{checks: [], metrics: %{}, relay_info: nil, relay_info_body: nil}

    result =
      Enum.reduce(checks, initial, fn check, acc ->
        merge_probe_result(acc, check_result(check, target, timeout_ms))
      end)

    {:ok, result}
  end

  def probe(_target, _opts, _publish_opts),
    do: {:ok, %{checks: [], metrics: %{}, relay_info: nil, relay_info_body: nil}}

  defp merge_probe_result(acc, %{check: check, metric_key: metric_key, metric_value: metric_value}) do
    acc
    |> Map.update!(:checks, &[check | &1])
    |> Map.update!(:metrics, &Map.put(&1, metric_key, metric_value))
  end

  defp merge_probe_result(acc, %{
         check: check,
         relay_info: relay_info,
         relay_info_body: relay_info_body
       }) do
    acc
    |> Map.update!(:checks, &[check | &1])
    |> Map.put(:relay_info, relay_info)
    |> Map.put(:relay_info_body, relay_info_body)
  end

  defp merge_probe_result(acc, :skip), do: acc
  defp merge_probe_result(acc, {:error, _reason}), do: acc

  defp check_result(:open, target, timeout_ms) do
    case measure_websocket_connect(Map.fetch!(target, :relay_url), timeout_ms) do
      {:ok, metric_value} ->
        %{check: :open, metric_key: :rtt_open_ms, metric_value: metric_value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_result(:read, %{listener: listener} = target, timeout_ms) do
    if listener.auth.nip42_required do
      :skip
    else
      case measure_websocket_read(Map.fetch!(target, :relay_url), timeout_ms) do
        {:ok, metric_value} ->
          %{check: :read, metric_key: :rtt_read_ms, metric_value: metric_value}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_result(:nip11, target, timeout_ms) do
    case fetch_nip11(Map.fetch!(target, :relay_url), timeout_ms) do
      {:ok, relay_info, relay_info_body, _metric_value} ->
        %{check: :nip11, relay_info: relay_info, relay_info_body: relay_info_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_result(_check, _target, _timeout_ms), do: :skip

  defp measure_websocket_connect(relay_url, timeout_ms) do
    with {:ok, websocket} <- connect(relay_url, timeout_ms),
         {:ok, metric_value} <- await_connected(websocket, timeout_ms) do
      :ok = WebSockexClient.close(websocket)
      {:ok, metric_value}
    end
  end

  defp measure_websocket_read(relay_url, timeout_ms) do
    with {:ok, websocket} <- connect(relay_url, timeout_ms),
         {:ok, started_at} <- await_connected_started_at(websocket, timeout_ms),
         :ok <- WebSockexClient.send_json(websocket, ["COUNT", "nip66-probe", %{"kinds" => [1]}]),
         {:ok, metric_value} <- await_count_response(websocket, timeout_ms, started_at) do
      :ok = WebSockexClient.close(websocket)
      {:ok, metric_value}
    end
  end

  defp connect(relay_url, timeout_ms) do
    server = %{url: relay_url, tls: tls_config(relay_url)}

    WebSockexClient.connect(self(), server, websocket_opts: [timeout: timeout_ms, protocols: nil])
  end

  defp await_connected(websocket, timeout_ms) do
    with {:ok, started_at} <- await_connected_started_at(websocket, timeout_ms) do
      {:ok, monotonic_duration_ms(started_at)}
    end
  end

  defp await_connected_started_at(websocket, timeout_ms) do
    started_at = System.monotonic_time()

    receive do
      {:sync_transport, ^websocket, :connected, _metadata} -> {:ok, started_at}
      {:sync_transport, ^websocket, :disconnected, reason} -> {:error, reason}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp await_count_response(websocket, timeout_ms, started_at) do
    receive do
      {:sync_transport, ^websocket, :frame, ["COUNT", "nip66-probe", _payload]} ->
        {:ok, monotonic_duration_ms(started_at)}

      {:sync_transport, ^websocket, :frame, ["CLOSED", "nip66-probe", _message]} ->
        {:error, :closed}

      {:sync_transport, ^websocket, :disconnected, reason} ->
        {:error, reason}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp fetch_nip11(relay_url, timeout_ms) do
    started_at = System.monotonic_time()

    case Req.get(
           url: relay_info_url(relay_url),
           headers: [{"accept", "application/nostr+json"}],
           decode_body: false,
           connect_options: [timeout: timeout_ms],
           receive_timeout: timeout_ms
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, relay_info} when is_map(relay_info) ->
            {:ok, relay_info, body, monotonic_duration_ms(started_at)}

          {:error, reason} ->
            {:error, reason}

          _other ->
            {:error, :invalid_relay_info}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:relay_info_request_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp relay_info_url(relay_url) do
    relay_url
    |> URI.parse()
    |> Map.update!(:scheme, fn
      "wss" -> "https"
      "ws" -> "http"
    end)
    |> URI.to_string()
  end

  defp tls_config(relay_url) do
    case URI.parse(relay_url) do
      %URI{scheme: "wss", host: host} when is_binary(host) and host != "" ->
        %{mode: :required, hostname: host, pins: []}

      _other ->
        %{mode: :disabled}
    end
  end

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(&normalize_check/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_checks(_checks), do: []

  defp normalize_check(:open), do: :open
  defp normalize_check("open"), do: :open
  defp normalize_check(:read), do: :read
  defp normalize_check("read"), do: :read
  defp normalize_check(:nip11), do: :nip11
  defp normalize_check("nip11"), do: :nip11
  defp normalize_check(_check), do: nil

  defp monotonic_duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
