defmodule Parrhesia.E2E.NakCliTest do
  use Parrhesia.IntegrationCase, async: false

  @moduletag :nak_e2e

  setup_all do
    if is_nil(System.find_executable("nak")) do
      raise "nak executable not found in PATH"
    end

    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok = wait_for_server()
    :ok
  end

  setup do
    relay_http_url = relay_http_url()

    {:ok,
     relay_url: relay_ws_url(relay_http_url),
     relay_http_url: relay_http_url,
     author_secret_key: random_secret_key()}
  end

  test "nak relay returns NIP-11 metadata", %{
    relay_url: relay_url,
    relay_http_url: relay_http_url
  } do
    {ws_output, 0} = run_nak(["-q", "relay", relay_url])
    {http_output, 0} = run_nak(["-q", "relay", relay_http_url])

    ws_metadata = JSON.decode!(ws_output)
    http_metadata = JSON.decode!(http_output)

    assert ws_metadata["name"] == "Parrhesia"
    assert 11 in ws_metadata["supported_nips"]
    assert 98 in ws_metadata["supported_nips"]
    assert http_metadata["name"] == ws_metadata["name"]
  end

  test "nak event/req/count/search round-trip", %{
    relay_url: relay_url,
    author_secret_key: author_secret_key
  } do
    nonce = System.unique_integer([:positive])

    first =
      publish_event(relay_url,
        sec: author_secret_key,
        content: "nak-e2e-alpha-#{nonce}"
      )

    second =
      publish_event(relay_url,
        sec: author_secret_key,
        content: "nak-e2e-beta-#{nonce}"
      )

    events = req_events(relay_url, ["-k", "1", "-a", first["pubkey"], "-l", "10"])

    assert Enum.any?(events, fn event -> event["id"] == first["id"] end)
    assert Enum.any?(events, fn event -> event["id"] == second["id"] end)

    count = count_events(relay_url, ["-k", "1", "-a", first["pubkey"]])
    assert count >= 2

    [search_result] = req_events(relay_url, ["--search", "alpha-#{nonce}", "-k", "1", "-l", "5"])
    assert search_result["id"] == first["id"]
  end

  test "nak user a post -> user b reply -> user a refresh sees reply", %{
    relay_url: relay_url,
    author_secret_key: user_a_secret_key
  } do
    nonce = System.unique_integer([:positive])

    post =
      publish_event(relay_url,
        sec: user_a_secret_key,
        content: "nak-e2e-parent-#{nonce}"
      )

    user_b_secret_key = random_secret_key()

    reply =
      publish_event(relay_url,
        sec: user_b_secret_key,
        content: "nak-e2e-reply-#{nonce}",
        tags: ["e=#{post["id"]}", "p=#{post["pubkey"]}"]
      )

    refresh_results = req_events(relay_url, ["-k", "1", "-e", post["id"], "-l", "10"])

    assert Enum.any?(refresh_results, fn event -> event["id"] == reply["id"] end)
    assert Enum.any?(refresh_results, fn event -> event["pubkey"] == reply["pubkey"] end)
  end

  test "nak duplicate publish does not create additional events", %{
    relay_url: relay_url,
    author_secret_key: author_secret_key
  } do
    created_at = System.system_time(:second)
    content = "nak-e2e-dup-#{System.unique_integer([:positive])}"

    event =
      publish_event(relay_url,
        sec: author_secret_key,
        content: content,
        created_at: created_at
      )

    duplicate =
      publish_event(relay_url,
        sec: author_secret_key,
        content: content,
        created_at: created_at
      )

    assert duplicate["id"] == event["id"]

    assert req_events(relay_url, ["-i", event["id"], "-l", "5"]) |> Enum.map(& &1["id"]) == [
             event["id"]
           ]
  end

  test "nak kind 445 event query with #h filter", %{
    relay_url: relay_url,
    author_secret_key: author_secret_key
  } do
    group_id = String.duplicate("a", 64)

    group_event =
      publish_event(relay_url,
        sec: author_secret_key,
        kind: 445,
        tags: ["h=#{group_id}"],
        content: Base.encode64("nak-e2e-group")
      )

    assert req_events(relay_url, ["-k", "445", "-t", "h=#{group_id}", "-l", "5"])
           |> Enum.map(& &1["id"]) == [group_event["id"]]
  end

  test "nak deletion and vanish lifecycle", %{
    relay_url: relay_url,
    author_secret_key: author_secret_key
  } do
    first =
      publish_event(relay_url,
        sec: author_secret_key,
        content: "nak-e2e-delete-first-#{System.unique_integer([:positive])}"
      )

    second =
      publish_event(relay_url,
        sec: author_secret_key,
        content: "nak-e2e-delete-second-#{System.unique_integer([:positive])}"
      )

    _delete_request =
      publish_event(relay_url,
        sec: author_secret_key,
        kind: 5,
        tags: ["e=#{first["id"]}"],
        content: "delete"
      )

    assert req_events(relay_url, ["-i", first["id"], "-l", "5"]) == []

    assert req_events(relay_url, ["-i", second["id"], "-l", "5"]) |> Enum.map(& &1["id"]) == [
             second["id"]
           ]

    _vanish_request =
      publish_event(relay_url,
        sec: author_secret_key,
        kind: 62,
        content: "vanish"
      )

    assert req_events(relay_url, ["-a", first["pubkey"], "-l", "20"]) == []
  end

  defp publish_event(relay_url, opts) do
    sec = Keyword.fetch!(opts, :sec)
    kind = Keyword.get(opts, :kind, 1)
    content = Keyword.get(opts, :content, "")
    tags = Keyword.get(opts, :tags, [])

    created_at_args =
      case Keyword.get(opts, :created_at) do
        created_at when is_integer(created_at) -> ["--created-at", Integer.to_string(created_at)]
        _other -> []
      end

    tag_args = Enum.flat_map(tags, fn tag -> ["-t", tag] end)

    args =
      ["-q", "event", "--sec", sec, "-k", Integer.to_string(kind), "-c", content] ++
        created_at_args ++ tag_args ++ [relay_url]

    {output, 0} = run_nak(args)
    JSON.decode!(output)
  end

  defp req_events(relay_url, filter_args) do
    {output, 0} = run_nak(["-q", "req" | filter_args] ++ [relay_url])

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp count_events(relay_url, filter_args) do
    {output, 0} = run_nak(["-q", "count" | filter_args] ++ [relay_url])

    case Regex.run(~r/:\s*(\d+)\s*$/, String.trim(output)) do
      [_, count] -> String.to_integer(count)
      _other -> flunk("unexpected nak count output: #{inspect(output)}")
    end
  end

  defp run_nak(args, timeout_ms \\ 5_000) do
    shell_command =
      ["nak" | args]
      |> Enum.map_join(" ", &shell_escape/1)
      |> Kernel.<>(" </dev/null 2>&1")

    task = Task.async(fn -> System.cmd("bash", ["-lc", shell_command]) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0} = success} ->
        success

      {:ok, {output, status}} ->
        flunk("nak command failed with status #{status}: #{shell_command}\n#{output}")

      nil ->
        flunk("nak command timed out after #{timeout_ms}ms: #{shell_command}")
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp wait_for_server do
    health_url = base_http_url() <> "/health"

    1..100
    |> Enum.reduce_while(:error, fn _attempt, _acc ->
      case Req.get(health_url, receive_timeout: 500, connect_options: [timeout: 500]) do
        {:ok, %{status: 200, body: "ok"}} ->
          {:halt, :ok}

        _other ->
          Process.sleep(100)
          {:cont, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> raise "server was not ready at #{health_url}"
    end
  end

  defp relay_http_url do
    base_http_url() <> "/relay"
  end

  defp base_http_url do
    port = System.get_env("PARRHESIA_NAK_E2E_RELAY_PORT") || "4050"
    "http://127.0.0.1:#{port}"
  end

  defp relay_ws_url(relay_http_url) do
    String.replace_prefix(relay_http_url, "http://", "ws://")
  end

  defp random_secret_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode16(case: :lower)
  end
end
