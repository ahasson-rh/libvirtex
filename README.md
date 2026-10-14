# Libvirtex

Libvirtex is an Elixir umbrella project for a lightweight distributed scheduler
of libvirt virtual machines. A central Command Control service accepts operator
requests and selects capacity; a scheduler agent on each hypervisor owns local
resource reservations and VM reconciliation. An IPAM integration reserves and
releases VM addresses as part of provisioning.

## Planned components

- **`command_control_module`** — central Phoenix web/API service in a Podman
  container on the bastion; owns inventory, desired VM state, placement
  coordination, and operations control.
- **`hypervisor_scheduler_module`** — one host-networked Podman container per
  hypervisor; supervises one VM Agent per managed VM, watches libvirt, and
  enforces local RAM/vCPU reservations.
- **`libvirtex_core`** — shared domain types, behaviour contracts, validation,
  and protocol messages. It must not own runtime state.
- **`libvirtex_cluster`** — libcluster/Mnesia-based cluster formation and
  distributed scheduling registry.
- **`libvirtex_ipam`** — IPAM behaviour plus provider adapters; address leases
  are tied to VM lifecycle and compensated on failed provisioning.
- **`libvirtex_provisioner`** — optional hypervisor-instantiation behaviour and
  adapters for environments that can grow beyond static inventory.

See [the system design and delivery plan](docs/system-design.md) for component
boundaries, workflows, failure handling, and phased implementation.
The [IPAM fallback-election plan](docs/ipam-fallback-election.md) details how
CCM retries placement on a different HSM when an elected subnet is exhausted.
Deployment roles, inventory layout, secret handling, and rollout checks are
defined in [the Ansible provisioning design](docs/ansible-provisioning.md).

