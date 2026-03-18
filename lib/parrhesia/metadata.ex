defmodule Parrhesia.Metadata do
  @moduledoc false

  @metadata Application.compile_env(:parrhesia, :metadata, [])
  @name Keyword.get(@metadata, :name, "Parrhesia")
  @version Keyword.get(@metadata, :version, "0.0.0")
  @hide_version? Keyword.get(@metadata, :hide_version?, true)

  @spec name() :: String.t()
  def name, do: @name

  @spec version() :: String.t()
  def version, do: @version

  @spec hide_version?() :: boolean()
  def hide_version?, do: @hide_version?

  @spec name_and_version() :: String.t()
  def name_and_version, do: "#{@name}/#{@version}"

  @spec user_agent() :: String.t()
  def user_agent do
    if hide_version?() do
      name()
    else
      name_and_version()
    end
  end
end
