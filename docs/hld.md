# Libvirtex High-Level Design

## Overview

Libvirtex is a lightweight control plane for running libvirt virtual machines
across a fixed fleet of hypervisors. Operators and automation request a VM from
one central service. Libvirtex selects an eligible host, reserves the required
capacity and network address, creates the VM, and maintains its DNS mapping.

The design favors clear ownership and safe recovery over broad orchestration
features. It is intended for a single administrator-managed environment, not
as a general-purpose cloud or multi-region platform.

## Architectural Decisions

- **Central coordination with local enforcement.** The Command Control Module
  (CCM) makes fleet-wide placement decisions, while each Hypervisor Scheduler
  Module (HSM) makes the final local decision about whether its host has
  capacity. This avoids relying solely on potentially stale central data.
- **A fixed, declarative host fleet.** Hypervisors are not provisioned by
  Libvirtex. CCM loads the authoritative inventory file supplied in its
  configuration, and an HSM must authenticate and register before its host is
  eligible for work.
- **Explicit VM lifecycle.** VM creation, deletion, address management, and
  DNS updates are treated as one recoverable workflow with clear states and
  audit history.
- **Infrastructure integrations behind interfaces.** IP address management and
  CoreDNS record management are separate integrations. This allows the control
  plane to use the infrastructure chosen by an administrator without making
  it responsible for operating those services.
- **CoreDNS records are system-managed.** Libvirtex owns VM name-to-address
  mappings in a designated managed portion of the CoreDNS configuration. It
  adds a mapping after a VM is available and removes it before that VM's
  address can be reused.

## Major Components

| Component | High-level responsibility |
| --- | --- |
| Operator UI and API | Accept VM and fleet-management requests and expose their progress. |
| Command Control Module | Own the loaded inventory, desired VM state, placement decisions, workflow progress, and audit trail. |
| Hypervisor Scheduler Module | Register the host, enforce its local resource limits, and supervise its managed VMs. |
| VM Agent | Create, observe, reconcile, and retire one VM on its assigned host. |
| Inventory file | Defines the known hypervisors that CCM may accept and schedule onto. |
| IPAM | Allocates and releases VM addresses. |
| CoreDNS | Publishes and removes the DNS mappings for managed VM addresses. |

## VM Journey

1. An operator or automation submits a VM request to CCM.
2. CCM finds a suitable registered HSM and asks it to reserve capacity.
3. After the host accepts the reservation, CCM obtains an IP address from IPAM.
4. The selected HSM creates and monitors the VM.
5. Once the VM is confirmed, CCM publishes its DNS mapping in CoreDNS.
6. When the VM is retired, CCM removes the DNS mapping, retires the VM, and
   releases the address and host capacity.

If a step cannot complete, Libvirtex keeps enough workflow state to retry or
clean up safely. It does not silently reuse capacity or an address that may
still belong to a VM.

## System Boundaries

Libvirtex manages VM scheduling, lifecycle coordination, IP-address leases,
and the VM-record portion of CoreDNS. The infrastructure administrator remains
responsible for the hypervisors, libvirt installation, networking, routing,
firewalls, CoreDNS service availability, storage, backups, and deployment
environment.

The system intentionally does not provide live migration, distributed storage
management, automatic rescheduling after host loss, dynamic hypervisor
provisioning, or multi-region coordination.

## Expected Outcome

An operator has one place to request and retire VMs. Each VM has a known host,
an allocated address, and a managed DNS name; the system can explain the
current state of each step and recover safely when components restart or are
temporarily unavailable.
