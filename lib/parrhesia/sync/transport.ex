defmodule Parrhesia.Sync.Transport do
  @moduledoc false

  @callback connect(pid(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  @callback send_json(pid(), term()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
end
