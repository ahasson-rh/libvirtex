defmodule LibvirtexCore.VMLifecycle do
  @moduledoc "Validates explicit VM-request lifecycle transitions."

  alias LibvirtexCore.{Error, Domain.VMRequest}

  @transitions %{
    requested: [:placing, :failed],
    placing: [:reserved, :failed],
    reserved: [:ip_reserved, :failed],
    ip_reserved: [:provisioning, :failed],
    provisioning: [:running, :failed],
    running: [:unknown, :deleting],
    unknown: [:running, :deleting],
    deleting: [:absent],
    absent: [],
    failed: []
  }

  @spec transition(VMRequest.t(), VMRequest.lifecycle_state()) ::
          {:ok, VMRequest.t()} | {:error, Error.t()}
  def transition(%VMRequest{lifecycle_state: current} = request, next_state) do
    if next_state in Map.fetch!(@transitions, current) do
      {:ok, %{request | lifecycle_state: next_state}}
    else
      {:error,
       Error.new(:conflict, "invalid VM lifecycle transition",
         details: %{from: current, to: next_state}
       )}
    end
  end

  @spec allowed?(VMRequest.lifecycle_state(), VMRequest.lifecycle_state()) :: boolean()
  def allowed?(current, next_state), do: next_state in Map.get(@transitions, current, [])
end
