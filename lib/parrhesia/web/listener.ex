defmodule Parrhesia.Web.Listener do
  @moduledoc false

  import Bitwise

  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Web.TLS

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

  @type t :: %{
          id: atom(),
          enabled: boolean(),
          bind: %{ip: tuple(), port: pos_integer()},
          max_connections: pos_integer() | :infinity,
          transport: map(),
          proxy: map(),
          network: map(),
          features: map(),
          auth: map(),
          baseline_acl: map(),
          bandit_options: keyword()
        }

  @spec all() :: [t()]
  def all do
    :parrhesia
    |> Application.get_env(:listeners, %{})
    |> normalize_listeners()
    |> Enum.filter(& &1.enabled)
  end

  @spec from_opts(keyword() | map()) :: t()
  def from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:listener, default_listener())
    |> normalize_listener()
  end

  def from_opts(opts) when is_map(opts) do
    opts
    |> Map.get(:listener, default_listener())
    |> normalize_listener()
  end

  @spec from_conn(Plug.Conn.t()) :: t()
  def from_conn(conn) do
    conn.private
    |> Map.get(:parrhesia_listener, default_listener())
    |> normalize_listener()
  end

  @spec put_conn(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def put_conn(conn, opts) when is_list(opts) do
    Plug.Conn.put_private(conn, :parrhesia_listener, from_opts(opts))
  end

  @spec feature_enabled?(t(), atom()) :: boolean()
  def feature_enabled?(listener, feature) when is_map(listener) and is_atom(feature) do
    listener
    |> Map.get(:features, %{})
    |> Map.get(feature, %{})
    |> Map.get(:enabled, false)
  end

  @spec nip42_required?(t()) :: boolean()
  def nip42_required?(listener), do: listener.auth.nip42_required

  @spec admin_auth_required?(t()) :: boolean()
  def admin_auth_required?(listener), do: listener.auth.nip98_required_for_admin

  @spec trusted_proxies(t()) :: [String.t()]
  def trusted_proxies(listener) do
    listener.proxy.trusted_cidrs
  end

  @spec trusted_proxy_request?(t(), Plug.Conn.t()) :: boolean()
  def trusted_proxy_request?(listener, conn) do
    TLS.trusted_proxy_request?(conn, trusted_proxies(listener))
  end

  @spec remote_ip_allowed?(t(), tuple() | String.t() | nil) :: boolean()
  def remote_ip_allowed?(listener, remote_ip) do
    access_allowed?(listener.network, remote_ip)
  end

  @spec authorize_transport_request(t(), Plug.Conn.t()) ::
          {:ok, map() | nil} | {:error, atom()}
  def authorize_transport_request(listener, conn) do
    TLS.authorize_request(listener.transport.tls, conn, trusted_proxy_request?(listener, conn))
  end

  @spec request_scheme(t(), Plug.Conn.t()) :: :http | :https
  def request_scheme(listener, conn) do
    TLS.request_scheme(listener.transport.tls, conn, trusted_proxy_request?(listener, conn))
  end

  @spec request_host(t(), Plug.Conn.t()) :: String.t()
  def request_host(listener, conn) do
    TLS.request_host(conn, trusted_proxy_request?(listener, conn))
  end

  @spec request_port(t(), Plug.Conn.t()) :: non_neg_integer()
  def request_port(listener, conn) do
    scheme = request_scheme(listener, conn)
    TLS.request_port(listener.transport.tls, conn, trusted_proxy_request?(listener, conn), scheme)
  end

  @spec metrics_allowed?(t(), Plug.Conn.t()) :: boolean()
  def metrics_allowed?(listener, conn) do
    metrics = Map.get(listener.features, :metrics, %{})

    feature_enabled?(listener, :metrics) and
      access_allowed?(Map.get(metrics, :access, %{}), conn.remote_ip) and
      metrics_token_allowed?(metrics, conn)
  end

  @spec relay_url(t(), Plug.Conn.t()) :: String.t()
  def relay_url(listener, conn) do
    scheme = request_scheme(listener, conn)
    host = request_host(listener, conn)
    port = request_port(listener, conn)
    ws_scheme = if scheme == :https, do: "wss", else: "ws"

    port_segment =
      if default_http_port?(scheme, port) do
        ""
      else
        ":#{port}"
      end

    "#{ws_scheme}://#{host}#{port_segment}#{conn.request_path}"
  end

  @spec relay_auth_required?(t()) :: boolean()
  def relay_auth_required?(listener), do: listener.auth.nip42_required

  @spec authorize_read(t(), [map()]) :: :ok | {:error, :listener_read_not_allowed}
  def authorize_read(listener, filters) when is_list(filters) do
    case evaluate_rules(listener.baseline_acl.read, filters, :read) do
      :allow -> :ok
      :deny -> {:error, :listener_read_not_allowed}
    end
  end

  @spec authorize_write(t(), map()) :: :ok | {:error, :listener_write_not_allowed}
  def authorize_write(listener, event) when is_map(event) do
    case evaluate_rules(listener.baseline_acl.write, event, :write) do
      :allow -> :ok
      :deny -> {:error, :listener_write_not_allowed}
    end
  end

  @spec bandit_options(t()) :: keyword()
  def bandit_options(listener) do
    scheme =
      case listener.transport.tls.mode do
        mode when mode in [:server, :mutual] -> :https
        _other -> listener.transport.scheme
      end

    thousand_island_options =
      listener.bandit_options
      |> Keyword.get(:thousand_island_options, [])
      |> maybe_put_connection_limit(listener.max_connections)

    [
      ip: listener.bind.ip,
      port: listener.bind.port,
      scheme: scheme,
      plug: {Parrhesia.Web.ListenerPlug, listener: listener}
    ] ++
      TLS.bandit_options(listener.transport.tls) ++
      [thousand_island_options: thousand_island_options] ++
      Keyword.delete(listener.bandit_options, :thousand_island_options)
  end

  defp normalize_listeners(listeners) when is_list(listeners) do
    Enum.map(listeners, fn
      {id, listener} when is_atom(id) and is_map(listener) ->
        normalize_listener(Map.put(listener, :id, id))

      listener when is_map(listener) ->
        normalize_listener(listener)
    end)
  end

  defp normalize_listeners(listeners) when is_map(listeners) do
    listeners
    |> Enum.map(fn {id, listener} -> normalize_listener(Map.put(listener, :id, id)) end)
    |> Enum.sort_by(& &1.id)
  end

  defp normalize_listener(listener) when is_map(listener) do
    id = normalize_atom(fetch_value(listener, :id), :listener)
    enabled = normalize_boolean(fetch_value(listener, :enabled), true)
    bind = normalize_bind(fetch_value(listener, :bind), listener)
    max_connections = normalize_max_connections(fetch_value(listener, :max_connections), id)
    transport = normalize_transport(fetch_value(listener, :transport))
    proxy = normalize_proxy(fetch_value(listener, :proxy))
    network = normalize_access(fetch_value(listener, :network), %{allow_all?: true})
    features = normalize_features(fetch_value(listener, :features))
    auth = normalize_auth(fetch_value(listener, :auth))
    baseline_acl = normalize_baseline_acl(fetch_value(listener, :baseline_acl))
    bandit_options = normalize_bandit_options(fetch_value(listener, :bandit_options))

    %{
      id: id,
      enabled: enabled,
      bind: bind,
      max_connections: max_connections,
      transport: transport,
      proxy: proxy,
      network: network,
      features: features,
      auth: auth,
      baseline_acl: baseline_acl,
      bandit_options: bandit_options
    }
  end

  defp normalize_listener(_listener), do: default_listener()

  defp normalize_bind(bind, listener) when is_map(bind) do
    %{
      ip: normalize_ip(fetch_value(bind, :ip), default_bind_ip(listener)),
      port: normalize_port(fetch_value(bind, :port), 4413)
    }
  end

  defp normalize_bind(_bind, listener) do
    %{
      ip: default_bind_ip(listener),
      port: normalize_port(fetch_value(listener, :port), 4413)
    }
  end

  defp normalize_max_connections(value, _listener_id) when is_integer(value) and value > 0,
    do: value

  defp normalize_max_connections(:infinity, _listener_id), do: :infinity
  defp normalize_max_connections("infinity", _listener_id), do: :infinity
  defp normalize_max_connections(_value, :metrics), do: 1_024
  defp normalize_max_connections(_value, _listener_id), do: 20_000

  defp default_bind_ip(listener) do
    normalize_ip(fetch_value(listener, :ip), {0, 0, 0, 0})
  end

  defp normalize_transport(transport) when is_map(transport) do
    scheme = normalize_scheme(fetch_value(transport, :scheme), :http)

    %{
      scheme: scheme,
      tls: TLS.normalize_config(fetch_value(transport, :tls), scheme)
    }
  end

  defp normalize_transport(_transport), do: %{scheme: :http, tls: TLS.default_config()}

  defp normalize_proxy(proxy) when is_map(proxy) do
    %{
      trusted_cidrs: normalize_string_list(fetch_value(proxy, :trusted_cidrs)),
      honor_x_forwarded_for: normalize_boolean(fetch_value(proxy, :honor_x_forwarded_for), true)
    }
  end

  defp normalize_proxy(_proxy), do: %{trusted_cidrs: [], honor_x_forwarded_for: true}

  defp normalize_features(features) when is_map(features) do
    %{
      nostr: normalize_simple_feature(fetch_value(features, :nostr), true),
      admin: normalize_simple_feature(fetch_value(features, :admin), true),
      metrics: normalize_metrics_feature(fetch_value(features, :metrics))
    }
  end

  defp normalize_features(_features) do
    %{
      nostr: %{enabled: true},
      admin: %{enabled: true},
      metrics: %{enabled: false, access: default_feature_access()}
    }
  end

  defp normalize_simple_feature(feature, default_enabled) when is_map(feature) do
    %{enabled: normalize_boolean(fetch_value(feature, :enabled), default_enabled)}
  end

  defp normalize_simple_feature(feature, _default_enabled) when is_boolean(feature) do
    %{enabled: feature}
  end

  defp normalize_simple_feature(_feature, default_enabled), do: %{enabled: default_enabled}

  defp normalize_metrics_feature(feature) when is_map(feature) do
    %{
      enabled: normalize_boolean(fetch_value(feature, :enabled), false),
      auth_token: normalize_optional_string(fetch_value(feature, :auth_token)),
      access:
        normalize_access(fetch_value(feature, :access), %{
          private_networks_only?: false,
          allow_all?: true
        })
    }
  end

  defp normalize_metrics_feature(feature) when is_boolean(feature) do
    %{enabled: feature, auth_token: nil, access: default_feature_access()}
  end

  defp normalize_metrics_feature(_feature),
    do: %{enabled: false, auth_token: nil, access: default_feature_access()}

  defp default_feature_access do
    %{public?: false, private_networks_only?: false, allow_cidrs: [], allow_all?: true}
  end

  defp normalize_auth(auth) when is_map(auth) do
    %{
      nip42_required: normalize_boolean(fetch_value(auth, :nip42_required), false),
      nip98_required_for_admin:
        normalize_boolean(fetch_value(auth, :nip98_required_for_admin), true)
    }
  end

  defp normalize_auth(_auth), do: %{nip42_required: false, nip98_required_for_admin: true}

  defp normalize_baseline_acl(acl) when is_map(acl) do
    %{
      read: normalize_baseline_rules(fetch_value(acl, :read)),
      write: normalize_baseline_rules(fetch_value(acl, :write))
    }
  end

  defp normalize_baseline_acl(_acl), do: %{read: [], write: []}

  defp normalize_baseline_rules(rules) when is_list(rules) do
    Enum.flat_map(rules, fn
      %{match: match} = rule when is_map(match) ->
        [
          %{
            action: normalize_rule_action(fetch_value(rule, :action)),
            match: normalize_filter_map(match)
          }
        ]

      _other ->
        []
    end)
  end

  defp normalize_baseline_rules(_rules), do: []

  defp normalize_rule_action(:deny), do: :deny
  defp normalize_rule_action("deny"), do: :deny
  defp normalize_rule_action(_action), do: :allow

  defp normalize_bandit_options(options) when is_list(options), do: options
  defp normalize_bandit_options(_options), do: []

  defp maybe_put_connection_limit(thousand_island_options, :infinity)
       when is_list(thousand_island_options),
       do: Keyword.put_new(thousand_island_options, :num_connections, :infinity)

  defp maybe_put_connection_limit(thousand_island_options, max_connections)
       when is_list(thousand_island_options) and is_integer(max_connections) and
              max_connections > 0 do
    num_acceptors =
      case Keyword.get(thousand_island_options, :num_acceptors, 100) do
        value when is_integer(value) and value > 0 -> value
        _other -> 100
      end

    per_acceptor_limit = ceil(max_connections / num_acceptors)
    Keyword.put_new(thousand_island_options, :num_connections, per_acceptor_limit)
  end

  defp maybe_put_connection_limit(thousand_island_options, _max_connections)
       when is_list(thousand_island_options),
       do: thousand_island_options

  defp normalize_access(access, defaults) when is_map(access) do
    %{
      public?:
        normalize_boolean(
          first_present(access, [:public, :public?]),
          Map.get(defaults, :public?, false)
        ),
      private_networks_only?:
        normalize_boolean(
          first_present(access, [:private_networks_only, :private_networks_only?]),
          Map.get(defaults, :private_networks_only?, false)
        ),
      allow_cidrs: normalize_string_list(fetch_value(access, :allow_cidrs)),
      allow_all?:
        normalize_boolean(
          first_present(access, [:allow_all, :allow_all?]),
          Map.get(defaults, :allow_all?, false)
        )
    }
  end

  defp normalize_access(_access, defaults) do
    %{
      public?: Map.get(defaults, :public?, false),
      private_networks_only?: Map.get(defaults, :private_networks_only?, false),
      allow_cidrs: [],
      allow_all?: Map.get(defaults, :allow_all?, false)
    }
  end

  defp access_allowed?(%{public?: true}, _remote_ip), do: true

  defp access_allowed?(%{allow_cidrs: allow_cidrs}, remote_ip) when allow_cidrs != [] do
    Enum.any?(allow_cidrs, &ip_in_cidr?(remote_ip, &1))
  end

  defp access_allowed?(%{private_networks_only?: true}, remote_ip) do
    Enum.any?(@private_cidrs, &ip_in_cidr?(remote_ip, &1))
  end

  defp access_allowed?(%{allow_all?: allow_all?}, _remote_ip), do: allow_all?

  defp metrics_token_allowed?(metrics, conn) do
    case metrics.auth_token do
      nil ->
        true

      token ->
        conn
        |> Plug.Conn.get_req_header("authorization")
        |> List.first()
        |> normalize_authorization_header()
        |> Kernel.==(token)
    end
  end

  defp normalize_authorization_header("Bearer " <> token), do: token
  defp normalize_authorization_header(token) when is_binary(token), do: token
  defp normalize_authorization_header(_header), do: nil

  defp evaluate_rules([], _subject, _mode), do: :allow

  defp evaluate_rules(rules, subject, mode) do
    has_allow_rules? = Enum.any?(rules, &(&1.action == :allow))

    case Enum.find(rules, &rule_matches?(&1, subject, mode)) do
      %{action: :deny} -> :deny
      %{action: :allow} -> :allow
      nil when has_allow_rules? -> :deny
      nil -> :allow
    end
  end

  defp rule_matches?(rule, filters, :read) when is_list(filters) do
    Enum.any?(filters, &filters_overlap?(&1, rule.match))
  end

  defp rule_matches?(rule, event, :write) when is_map(event) do
    Filter.matches_filter?(event, rule.match)
  end

  defp rule_matches?(_rule, _subject, _mode), do: false

  defp filters_overlap?(left, right) when is_map(left) and is_map(right) do
    comparable_keys =
      left
      |> Map.keys()
      |> Kernel.++(Map.keys(right))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in ["limit", "search", "since", "until"]))

    Enum.all?(comparable_keys, fn key ->
      filter_constraint_compatible?(Map.get(left, key), Map.get(right, key))
    end) and filter_ranges_overlap?(left, right)
  end

  defp filter_constraint_compatible?(nil, _right), do: true
  defp filter_constraint_compatible?(_left, nil), do: true

  defp filter_constraint_compatible?(left, right) when is_list(left) and is_list(right) do
    not MapSet.disjoint?(MapSet.new(left), MapSet.new(right))
  end

  defp filter_constraint_compatible?(left, right), do: left == right

  defp filter_ranges_overlap?(left, right) do
    since = max(Map.get(left, "since", 0), Map.get(right, "since", 0))

    until =
      min(
        Map.get(left, "until", 9_223_372_036_854_775_807),
        Map.get(right, "until", 9_223_372_036_854_775_807)
      )

    since <= until
  end

  defp default_listener do
    case configured_default_listener() do
      nil -> fallback_listener()
      listener -> normalize_listener(listener)
    end
  end

  defp configured_default_listener do
    listeners = Application.get_env(:parrhesia, :listeners, %{})

    case fetch_public_listener(listeners) do
      nil -> first_configured_listener(listeners)
      listener -> listener
    end
  end

  defp fetch_public_listener(%{public: listener}) when is_map(listener),
    do: Map.put_new(listener, :id, :public)

  defp fetch_public_listener(listeners) when is_list(listeners) do
    case Keyword.fetch(listeners, :public) do
      {:ok, listener} when is_map(listener) -> Map.put_new(listener, :id, :public)
      _other -> nil
    end
  end

  defp fetch_public_listener(_listeners), do: nil

  defp first_configured_listener(listeners) when is_list(listeners) do
    case listeners do
      [{id, listener} | _rest] when is_atom(id) and is_map(listener) ->
        Map.put_new(listener, :id, id)

      _other ->
        nil
    end
  end

  defp first_configured_listener(listeners) when is_map(listeners) and map_size(listeners) > 0 do
    {id, listener} = Enum.at(Enum.sort_by(listeners, fn {key, _value} -> key end), 0)
    Map.put_new(listener, :id, id)
  end

  defp first_configured_listener(_listeners), do: nil

  defp fallback_listener do
    %{
      id: :public,
      enabled: true,
      bind: %{ip: {0, 0, 0, 0}, port: 4413},
      max_connections: 20_000,
      transport: %{scheme: :http, tls: TLS.default_config()},
      proxy: %{trusted_cidrs: [], honor_x_forwarded_for: true},
      network: %{public?: false, private_networks_only?: false, allow_cidrs: [], allow_all?: true},
      features: %{
        nostr: %{enabled: true},
        admin: %{enabled: true},
        metrics: %{enabled: false, auth_token: nil, access: default_feature_access()}
      },
      auth: %{nip42_required: false, nip98_required_for_admin: true},
      baseline_acl: %{read: [], write: []},
      bandit_options: []
    }
  end

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

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      cond do
        Map.has_key?(map, key) ->
          {:present, Map.get(map, key)}

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          {:present, Map.get(map, Atom.to_string(key))}

        true ->
          nil
      end
    end)
    |> case do
      {:present, value} -> value
      nil -> nil
    end
  end

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(nil, default), do: default
  defp normalize_boolean(_value, default), do: default

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    Enum.filter(values, &(is_binary(&1) and &1 != ""))
  end

  defp normalize_string_list(_values), do: []

  defp normalize_ip({_, _, _, _} = ip, _default), do: ip
  defp normalize_ip({_, _, _, _, _, _, _, _} = ip, _default), do: ip
  defp normalize_ip(_ip, default), do: default

  defp normalize_port(port, _default) when is_integer(port) and port > 0, do: port
  defp normalize_port(0, _default), do: 0
  defp normalize_port(_port, default), do: default

  defp normalize_scheme(:https, _default), do: :https
  defp normalize_scheme("https", _default), do: :https
  defp normalize_scheme(_scheme, default), do: default

  defp normalize_atom(value, _default) when is_atom(value), do: value
  defp normalize_atom(_value, default), do: default

  defp normalize_filter_map(filter) when is_map(filter) do
    Map.new(filter, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_filter_map(filter), do: filter

  defp default_http_port?(:http, 80), do: true
  defp default_http_port?(:https, 443), do: true
  defp default_http_port?(_scheme, _port), do: false

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
