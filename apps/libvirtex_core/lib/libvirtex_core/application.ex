defmodule LibvirtexCore.Application do
  @moduledoc "Supervision root for dependency-free shared contracts."

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: LibvirtexCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
