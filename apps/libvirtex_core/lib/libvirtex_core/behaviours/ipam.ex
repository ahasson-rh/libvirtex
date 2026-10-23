defmodule LibvirtexCore.Behaviours.IPAM do
  @moduledoc "Contract for subnet-aware IP address management providers."

  alias LibvirtexCore.{Error, Domain.IPLease}

  @type request :: %{
          vm_request_id: String.t(),
          hypervisor_id: String.t(),
          subnet_id: String.t(),
          idempotency_key: String.t()
        }
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @callback reserve(request()) :: result(IPLease.t())
  @callback confirm(IPLease.provider_ref()) :: result(IPLease.t())
  @callback release(IPLease.provider_ref()) :: :ok | {:error, Error.t()}
  @callback lookup(IPLease.provider_ref()) :: result(IPLease.t() | nil)
end
