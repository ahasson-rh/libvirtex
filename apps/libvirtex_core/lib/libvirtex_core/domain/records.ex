defmodule LibvirtexCore.Domain.SchedulingRequest do
  @moduledoc "An immutable generation of a distributed scheduling request."
  @enforce_keys [:vm_request_id, :generation]
  defstruct [:vm_request_id, :generation, :offer_deadline, offers: [], excluded_subnet_ids: []]
end

defmodule LibvirtexCore.Domain.Offer do
  @moduledoc "A provisional, expiring resource offer from an HSM."
  @enforce_keys [:hsm_id, :request_generation, :reservation_id, :expires_at]
  defstruct [
    :hsm_id,
    :request_generation,
    :reservation_id,
    :expires_at,
    :resources,
    :rejection_reason
  ]
end

defmodule LibvirtexCore.Domain.Placement do
  @moduledoc "The one active placement for a VM request."
  @enforce_keys [:vm_request_id, :hypervisor_id, :reservation_id, :generation]
  defstruct [:vm_request_id, :hypervisor_id, :reservation_id, :generation, :expires_at]
end

defmodule LibvirtexCore.Domain.IPLease do
  @moduledoc "An IPAM lease associated with a VM request and hypervisor."
  @enforce_keys [:provider_ref, :address, :prefix, :vm_request_id, :hypervisor_id, :subnet_id]

  defstruct [
    :provider_ref,
    :address,
    :prefix,
    :network,
    :vm_request_id,
    :hypervisor_id,
    :subnet_id,
    state: :reserved
  ]

  @type provider_ref :: term()

  @type t :: %__MODULE__{
          provider_ref: provider_ref(),
          address: String.t(),
          prefix: non_neg_integer(),
          network: String.t() | nil,
          vm_request_id: String.t(),
          hypervisor_id: String.t(),
          subnet_id: String.t(),
          state: atom()
        }
end

defmodule LibvirtexCore.Domain.DNSRecord do
  @moduledoc "A Libvirtex-managed CoreDNS mapping for a VM."
  @enforce_keys [:vm_request_id, :fqdn, :address, :zone]
  defstruct [:vm_request_id, :fqdn, :address, :zone, :provider_ref, state: :pending]

  @type t :: %__MODULE__{
          vm_request_id: String.t(),
          fqdn: String.t(),
          address: String.t(),
          zone: String.t(),
          provider_ref: term() | nil,
          state: atom()
        }
end

defmodule LibvirtexCore.Domain.VMRecord do
  @moduledoc "The HSM-owned observed and desired state for one VM."
  @enforce_keys [:vm_request_id, :hypervisor_id, :placement_generation]
  defstruct [
    :vm_request_id,
    :domain_identity,
    :hypervisor_id,
    :reservation_id,
    :lease_ref,
    :role,
    :workload_id,
    :placement_generation,
    desired_state: :running,
    observed_state: :unknown
  ]
end

defmodule LibvirtexCore.Domain.Operation do
  @moduledoc "A durable, idempotent external workflow action."
  @enforce_keys [:id, :idempotency_key, :step]
  defstruct [:id, :idempotency_key, :step, :error, :started_at, :completed_at, retry_count: 0]
end

defmodule LibvirtexCore.Domain.IPAMAttempt do
  @moduledoc "An auditable IPAM allocation attempt."
  @enforce_keys [:request_generation, :hypervisor_id, :subnet_id, :idempotency_key]
  defstruct [
    :request_generation,
    :hypervisor_id,
    :subnet_id,
    :idempotency_key,
    :outcome,
    :provider_error_category
  ]
end
