defmodule Parrhesia.Web.RelayInfoTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Web.Listener
  alias Parrhesia.Web.RelayInfo

  test "nip-11 omits version when metadata hides it" do
    document =
      :parrhesia
      |> Application.get_env(:listeners, %{})
      |> Keyword.fetch!(:public)
      |> then(&Listener.from_opts(listener: &1))
      |> RelayInfo.document()

    refute Map.has_key?(document, "version")
  end
end
