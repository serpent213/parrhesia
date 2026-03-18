defmodule Parrhesia.HTTP do
  @moduledoc false

  alias Parrhesia.Metadata

  @default_headers [{"user-agent", Metadata.user_agent()}]

  @spec default_headers() :: [{String.t(), String.t()}]
  def default_headers, do: @default_headers

  @spec get(Keyword.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(options) when is_list(options) do
    Req.get(put_default_headers(options))
  end

  @spec post(Keyword.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(options) when is_list(options) do
    Req.post(put_default_headers(options))
  end

  @spec put_default_headers(Keyword.t()) :: Keyword.t()
  def put_default_headers(options) when is_list(options) do
    Keyword.update(options, :headers, @default_headers, &merge_headers(&1, @default_headers))
  end

  defp merge_headers(headers, defaults) do
    existing_names =
      headers
      |> List.wrap()
      |> Enum.reduce(MapSet.new(), fn
        {name, _value}, acc -> MapSet.put(acc, normalize_header_name(name))
        _other, acc -> acc
      end)

    headers ++
      Enum.reject(defaults, fn {name, _value} ->
        MapSet.member?(existing_names, normalize_header_name(name))
      end)
  end

  defp normalize_header_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.downcase()
  end

  defp normalize_header_name(name) when is_binary(name), do: String.downcase(name)
end
