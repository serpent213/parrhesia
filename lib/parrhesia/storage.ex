defmodule Parrhesia.Storage do
  @moduledoc """
  Storage boundary entrypoint.

  Domain/runtime code should resolve behavior modules through this module instead of
  depending on concrete adapter implementations directly.
  """

  @default_modules [
    events: Parrhesia.Storage.Adapters.Postgres.Events,
    moderation: Parrhesia.Storage.Adapters.Postgres.Moderation,
    groups: Parrhesia.Storage.Adapters.Postgres.Groups,
    admin: Parrhesia.Storage.Adapters.Postgres.Admin
  ]

  @spec events() :: module()
  def events, do: fetch_module!(:events, Parrhesia.Storage.Events)

  @spec moderation() :: module()
  def moderation, do: fetch_module!(:moderation, Parrhesia.Storage.Moderation)

  @spec groups() :: module()
  def groups, do: fetch_module!(:groups, Parrhesia.Storage.Groups)

  @spec admin() :: module()
  def admin, do: fetch_module!(:admin, Parrhesia.Storage.Admin)

  defp fetch_module!(key, behavior) do
    module =
      :parrhesia
      |> Application.get_env(:storage, [])
      |> Keyword.get(key, Keyword.fetch!(@default_modules, key))

    ensure_behavior!(module, behavior, key)
  end

  defp ensure_behavior!(module, behavior, key) do
    case Code.ensure_loaded(module) do
      {:module, _loaded_module} ->
        if implements_behavior?(module, behavior) do
          module
        else
          raise ArgumentError,
                "configured storage module #{inspect(module)} for #{inspect(key)} " <>
                  "does not implement #{inspect(behavior)}"
        end

      {:error, reason} ->
        raise ArgumentError,
              "configured storage module #{inspect(module)} for #{inspect(key)} could not be loaded: " <>
                "#{inspect(reason)}"
    end
  end

  defp implements_behavior?(module, behavior) do
    module
    |> module_info_attributes()
    |> Keyword.get(:behaviour, [])
    |> Enum.member?(behavior)
  end

  defp module_info_attributes(module), do: module.module_info(:attributes)
end
