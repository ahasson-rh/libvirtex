defmodule LibvirtexCore.Domain.Hypervisor do
  @moduledoc "Configured hypervisor inventory and its most recent HSM identity."

  @enforce_keys [:id, :address, :ram_bytes, :vcpus, :ipam_subnet_id]
  defstruct [
    :id,
    :address,
    :ram_bytes,
    :vcpus,
    :ipam_subnet_id,
    :agent_identity,
    :last_heartbeat_at,
    labels: %{},
    capabilities: [],
    state: :disabled
  ]

  @type state :: :disabled | :enabled | :draining | :unreachable

  @type t :: %__MODULE__{
          id: String.t(),
          address: String.t(),
          ram_bytes: pos_integer(),
          vcpus: pos_integer(),
          ipam_subnet_id: String.t(),
          agent_identity: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          labels: map(),
          capabilities: [atom()],
          state: state()
        }
end
