defmodule Parrhesia.NIP66 do
  @moduledoc false

  alias Parrhesia.API.Events
  alias Parrhesia.API.Identity
  alias Parrhesia.API.RequestContext
  alias Parrhesia.NIP66.Probe
  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.RelayInfo

  @default_publish_interval_seconds 900
  @default_timeout_ms 5_000
  @default_checks [:open, :read, :nip11]
  @allowed_requirement_keys MapSet.new(~w[auth writes pow payment])

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    config = config(opts)
    config_enabled?(config) and active_targets(config, listeners(opts)) != []
  end

  @spec publish_snapshot(keyword()) :: {:ok, [map()]}
  def publish_snapshot(opts \\ []) when is_list(opts) do
    config = config(opts)
    targets = active_targets(config, listeners(opts))

    if config_enabled?(config) and targets != [] do
      probe_fun = Keyword.get(opts, :probe_fun, &Probe.probe/3)
      context = Keyword.get(opts, :context, %RequestContext{})
      now = Keyword.get(opts, :now, System.system_time(:second))
      identity_opts = identity_opts(opts)

      events =
        maybe_publish_monitor_announcement(config, now, context, identity_opts)
        |> Kernel.++(
          publish_discovery_events(targets, config, probe_fun, now, context, identity_opts)
        )

      {:ok, events}
    else
      {:ok, []}
    end
  end

  @spec publish_interval_ms(keyword()) :: pos_integer()
  def publish_interval_ms(opts \\ []) when is_list(opts) do
    config = config(opts)

    config
    |> Keyword.get(:publish_interval_seconds, @default_publish_interval_seconds)
    |> normalize_positive_integer(@default_publish_interval_seconds)
    |> Kernel.*(1_000)
  end

  defp maybe_publish_monitor_announcement(config, now, context, identity_opts) do
    if Keyword.get(config, :publish_monitor_announcement?, true) do
      config
      |> build_monitor_announcement(now)
      |> sign_and_publish(context, identity_opts)
      |> maybe_wrap_event()
    else
      []
    end
  end

  defp publish_discovery_events(targets, config, probe_fun, now, context, identity_opts) do
    probe_opts = [
      timeout_ms:
        config
        |> Keyword.get(:timeout_ms, @default_timeout_ms)
        |> normalize_positive_integer(@default_timeout_ms),
      checks: normalize_checks(Keyword.get(config, :checks, @default_checks))
    ]

    Enum.flat_map(targets, fn target ->
      probe_result =
        case probe_fun.(target, probe_opts, identity_opts) do
          {:ok, result} when is_map(result) -> result
          _other -> %{checks: [], metrics: %{}, relay_info: nil, relay_info_body: nil}
        end

      target
      |> build_discovery_event(now, probe_result, identity_opts)
      |> sign_and_publish(context, identity_opts)
      |> maybe_wrap_event()
    end)
  end

  defp sign_and_publish(event, context, identity_opts) do
    with {:ok, signed_event} <- Identity.sign_event(event, identity_opts),
         {:ok, %{accepted: true}} <- Events.publish(signed_event, context: context) do
      {:ok, signed_event}
    else
      _other -> :error
    end
  end

  defp maybe_wrap_event({:ok, event}), do: [event]
  defp maybe_wrap_event(_other), do: []

  defp build_monitor_announcement(config, now) do
    checks = normalize_checks(Keyword.get(config, :checks, @default_checks))
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    frequency = Keyword.get(config, :publish_interval_seconds, @default_publish_interval_seconds)

    tags =
      [
        [
          "frequency",
          Integer.to_string(
            normalize_positive_integer(frequency, @default_publish_interval_seconds)
          )
        ]
      ] ++
        Enum.map(checks, fn check ->
          ["timeout", Atom.to_string(check), Integer.to_string(timeout_ms)]
        end) ++
        Enum.map(checks, fn check -> ["c", Atom.to_string(check)] end) ++
        maybe_geohash_tag(config)

    %{
      "created_at" => now,
      "kind" => 10_166,
      "tags" => tags,
      "content" => ""
    }
  end

  defp build_discovery_event(target, now, probe_result, identity_opts) do
    relay_info = probe_result[:relay_info] || local_relay_info(target.listener, identity_opts)
    content = probe_result[:relay_info_body] || JSON.encode!(relay_info)

    tags =
      [["d", target.relay_url]]
      |> append_network_tag(target)
      |> append_relay_type_tag(target)
      |> append_geohash_tag(target)
      |> append_topic_tags(target)
      |> Kernel.++(nip_tags(relay_info))
      |> Kernel.++(requirement_tags(relay_info))
      |> Kernel.++(rtt_tags(probe_result[:metrics] || %{}))

    %{
      "created_at" => now,
      "kind" => 30_166,
      "tags" => tags,
      "content" => content
    }
  end

  defp nip_tags(relay_info) do
    relay_info
    |> Map.get("supported_nips", [])
    |> Enum.map(&["N", Integer.to_string(&1)])
  end

  defp requirement_tags(relay_info) do
    limitation = Map.get(relay_info, "limitation", %{})

    [
      requirement_value("auth", Map.get(limitation, "auth_required", false)),
      requirement_value("writes", Map.get(limitation, "restricted_writes", false)),
      requirement_value("pow", Map.get(limitation, "min_pow_difficulty", 0) > 0),
      requirement_value("payment", Map.get(limitation, "payment_required", false))
    ]
    |> Enum.filter(&MapSet.member?(@allowed_requirement_keys, String.trim_leading(&1, "!")))
    |> Enum.map(&["R", &1])
  end

  defp requirement_value(name, true), do: name
  defp requirement_value(name, false), do: "!" <> name

  defp rtt_tags(metrics) when is_map(metrics) do
    []
    |> maybe_put_metric_tag("rtt-open", Map.get(metrics, :rtt_open_ms))
    |> maybe_put_metric_tag("rtt-read", Map.get(metrics, :rtt_read_ms))
    |> maybe_put_metric_tag("rtt-write", Map.get(metrics, :rtt_write_ms))
  end

  defp append_network_tag(tags, target) do
    case target.network do
      nil -> tags
      value -> tags ++ [["n", value]]
    end
  end

  defp append_relay_type_tag(tags, target) do
    case target.relay_type do
      nil -> tags
      value -> tags ++ [["T", value]]
    end
  end

  defp append_geohash_tag(tags, target) do
    case target.geohash do
      nil -> tags
      value -> tags ++ [["g", value]]
    end
  end

  defp append_topic_tags(tags, target) do
    tags ++ Enum.map(target.topics, &["t", &1])
  end

  defp maybe_put_metric_tag(tags, _name, nil), do: tags

  defp maybe_put_metric_tag(tags, name, value) when is_integer(value) and value >= 0 do
    tags ++ [[name, Integer.to_string(value)]]
  end

  defp maybe_put_metric_tag(tags, _name, _value), do: tags

  defp local_relay_info(listener, identity_opts) do
    relay_info = RelayInfo.document(listener)

    case Identity.get(identity_opts) do
      {:ok, %{pubkey: pubkey}} ->
        relay_info
        |> Map.put("pubkey", pubkey)
        |> Map.put("self", pubkey)

      {:error, _reason} ->
        relay_info
    end
  end

  defp maybe_geohash_tag(config) do
    case fetch_value(config, :geohash) do
      value when is_binary(value) and value != "" -> [["g", value]]
      _other -> []
    end
  end

  defp active_targets(config, listeners) do
    listeners_by_id = Map.new(listeners, &{&1.id, &1})

    raw_targets =
      case Keyword.get(config, :targets, []) do
        [] -> [default_target()]
        targets when is_list(targets) -> targets
        _other -> []
      end

    Enum.flat_map(raw_targets, fn raw_target ->
      case normalize_target(raw_target, listeners_by_id) do
        {:ok, target} -> [target]
        :error -> []
      end
    end)
  end

  defp normalize_target(target, listeners_by_id) when is_map(target) or is_list(target) do
    listener_id = fetch_value(target, :listener) || :public
    relay_url = fetch_value(target, :relay_url) || Application.get_env(:parrhesia, :relay_url)

    with %{} = listener <- Map.get(listeners_by_id, normalize_listener_id(listener_id)),
         true <- listener.enabled and Listener.feature_enabled?(listener, :nostr),
         {:ok, normalized_relay_url} <- normalize_relay_url(relay_url) do
      {:ok,
       %{
         listener: listener,
         relay_url: normalized_relay_url,
         network: normalize_network(fetch_value(target, :network), normalized_relay_url),
         relay_type: normalize_optional_string(fetch_value(target, :relay_type)),
         geohash: normalize_optional_string(fetch_value(target, :geohash)),
         topics: normalize_string_list(fetch_value(target, :topics))
       }}
    else
      _other -> :error
    end
  end

  defp normalize_target(_target, _listeners_by_id), do: :error

  defp normalize_relay_url(relay_url) when is_binary(relay_url) and relay_url != "" do
    case URI.parse(relay_url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        normalized_uri = %URI{
          uri
          | scheme: String.downcase(scheme),
            host: String.downcase(host),
            path: normalize_path(uri.path),
            query: nil,
            fragment: nil,
            port: normalize_port(uri.port, scheme)
        }

        {:ok, URI.to_string(normalized_uri)}

      _other ->
        :error
    end
  end

  defp normalize_relay_url(_relay_url), do: :error

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path

  defp normalize_port(80, "ws"), do: nil
  defp normalize_port(443, "wss"), do: nil
  defp normalize_port(port, _scheme), do: port

  defp normalize_network(value, _relay_url)
       when is_binary(value) and value in ["clearnet", "tor", "i2p", "loki"],
       do: value

  defp normalize_network(_value, relay_url) do
    relay_url
    |> URI.parse()
    |> Map.get(:host)
    |> infer_network()
  end

  defp infer_network(host) when is_binary(host) do
    cond do
      String.ends_with?(host, ".onion") -> "tor"
      String.ends_with?(host, ".i2p") -> "i2p"
      true -> "clearnet"
    end
  end

  defp infer_network(_host), do: "clearnet"

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(&normalize_check/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_checks(_checks), do: @default_checks

  defp normalize_check(:open), do: :open
  defp normalize_check("open"), do: :open
  defp normalize_check(:read), do: :read
  defp normalize_check("read"), do: :read
  defp normalize_check(:nip11), do: :nip11
  defp normalize_check("nip11"), do: :nip11
  defp normalize_check(_check), do: nil

  defp listeners(opts) do
    case Keyword.get(opts, :listeners) do
      listeners when is_list(listeners) -> listeners
      _other -> Listener.all()
    end
  end

  defp identity_opts(opts) do
    opts
    |> Keyword.take([:path, :private_key, :configured_private_key])
  end

  defp config(opts) do
    case Keyword.get(opts, :config) do
      config when is_list(config) -> config
      _other -> Application.get_env(:parrhesia, :nip66, [])
    end
  end

  defp config_enabled?(config), do: Keyword.get(config, :enabled, true)

  defp default_target do
    %{listener: :public, relay_url: Application.get_env(:parrhesia, :relay_url)}
  end

  defp normalize_listener_id(value) when is_atom(value), do: value

  defp normalize_listener_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :public
  end

  defp normalize_listener_id(_value), do: :public

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    Enum.filter(values, &(is_binary(&1) and &1 != ""))
  end

  defp normalize_string_list(_values), do: []

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_value(list, key) when is_list(list) do
    if Keyword.keyword?(list), do: Keyword.get(list, key), else: nil
  end

  defp fetch_value(_container, _key), do: nil
end
