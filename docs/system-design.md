# Libvirtex System Design and Delivery Plan

## Purpose and Scope

Libvirtex schedules libvirt VMs onto a known inventory of hypervisors. It
begins with static inventory but can request a new hypervisor through a
pluggable provisioner when existing eligible capacity is exhausted. The system
tracks allocatable RAM and vCPUs, manages an IPAM lease per VM, and gives
operators a central web/API control plane.

The system is deliberately kept lightweight, not a general cluster orchestrator:
there is no VM live migration, distributed storage management, automatic VM rescheduling
after host loss, or multi-region consensus. 

## Operating Assumptions and Scope

The bastion and hypervisors are on an administrator-managed flat network.
Network reachability, routing, DNS, firewall policy, and the underlying bastion
and hypervisor infrastructure are the infrastructure administrator's
responsibility. Libvirtex assumes that CCM and every HSM can reach each other
over the configured authenticated control channel.

Provisioning KVM, libvirt, host networking, storage, and related hypervisor
dependencies is out of scope at this stage. Ansible and Podman are also assumed
to be installed and usable on the bastion and every hypervisor. The Ansible
automation deploys Libvirtex and validates these prerequisites; it does not
install or configure the host virtualization stack.

## Architecture

```text
Operator / automation
        |
 Phoenix UI + REST API
        |
CommandControlModule (Podman on bastion) ---- PostgreSQL (separate Podman container + local volume)
   |        |       \
   |        |        \-- IPAM provider
   |        +----------- hypervisor provisioner (optional)
   |
 libcluster / distributed Erlang / shared request registry
   |
HypervisorSchedulerModule (one per hypervisor, Podman --network host)
   |
DynamicSupervisor -> VM Agent (one per managed VM) -> libvirt local socket/API
                                                   |
                                                libvirtd ---- VMs
```

`CommandControlModule` is the source of truth for inventory, VM desired state,
workflow progress, placements, and IPAM lease references. Each
`HypervisorSchedulerModule` is authoritative only for whether its host can
honor a reservation and for observed local VM state. HSM continuously reports
reservation and observed-resource changes; CCM maintains the fleet-wide tracker
from those reports. That tracker is informative, not an admission guarantee:
the HSM's atomic local reservation ledger is authoritative for a host.

## Umbrella Applications and Boundaries

| Application | Responsibility | Must not own |
| --- | --- | --- |
| `command_control_module` | Phoenix UI/API, persistence, inventory, placement, workflow orchestration, audit events | libvirt calls or host-local accounting |
| `hypervisor_scheduler_module` | admission checks, durable local reservations, HSM reconciliation, and a supervised VM Agent per managed VM | global placement or IPAM credentials |
| `libvirtex_core` | structs, state transitions, validation, behaviours, request/event schemas | database, transport, or provider implementations |
| `libvirtex_cluster` | libcluster topology, node naming, Mnesia schema/tables, cluster event handling, and shared-registry interface | libvirt calls or host-local resource admission |
| `libvirtex_ipam` | `IPAM` behaviour and adapters for reserve, confirm, release, lookup | placement decisions or VM creation |
| `libvirtex_provisioner` | `Provisioner` behaviour and adapters that create/register hosts | host scheduling policy |

Start `libvirtex_core` as an independent app. Keep the IPAM and provisioner
apps independent when adapters are expected to be reusable or have their own
dependencies; otherwise begin as implementations beneath the control module
and extract without changing the core behaviour contracts.

`libvirtex_cluster` is the single owner of cluster configuration. CCM and HSM
depend on it rather than each maintaining their own libcluster topology or
node-discovery rules. It also owns Mnesia startup, table definitions, and
rejoin synchronization.

## Domain Model

Persist immutable IDs and explicit state transitions. Core records are:

- `Hypervisor`: ID, inventory source, address, enabled/draining state,
  allocatable limits, capabilities, IPAM subnet ID/prefix, agent identity, and
  last heartbeat. One enabled hypervisor maps to one IPAM allocation subnet.
- `VMRequest`: ID, caller/idempotency key, requested RAM/vCPUs, network/image
  specification, required/preferred host labels, workload-affinity or
  anti-affinity rules, desired state (`running` or `absent`), and lifecycle
  state.
- `SchedulingRequest`: an immutable request generation in the distributed
  shared registry, offer deadline, eligible-affinity rules, offers, IPAM
  attempt count, and subnets excluded for this generation.
- `Offer`: HSM ID, request generation, provisional reservation ID/expiry,
  offered resources, observed capacity revision, and rejection reason when
  applicable.
- `Placement`: VM request ID, hypervisor ID, reservation ID, generation, and
  expiry; only one active placement may exist per VM request.
- `IPLease`: provider reference, address/prefix/network, state, and VM request
  ID, hypervisor ID, and IPAM subnet ID. Store no provider secrets in this
  record.
- `VMRecord`: VM request ID, domain identity, elected HSM, reservation and
  lease references, desired/observed state, and placement generation. It is
  owned locally by that VM's HSM agent and replicated as cluster state.
- `Operation`: durable workflow step, retry count, error, timestamps, and an
  idempotency key for every remote action.
- `IPAMAttempt`: request generation, HSM/subnet, idempotency key, outcome, and
  provider error category. `subnet_exhausted` is distinct from transient and
  authentication/provider errors.

Suggested lifecycle: `requested -> placing -> reserved -> ip_reserved ->
provisioning -> running`; failures move to `failed` after compensating release
of reservation and unconfirmed lease. Deletion is `deleting -> absent`. A
running VM whose agent disappears becomes `unknown`, not immediately deleted.

## Scheduling, Offers, and Reservation Protocol

CCM publishes each validated VM request as a generation-scoped entry in a
Mnesia-backed distributed shared registry. `libcluster` forms the distributed
Erlang cluster that lets CCM and HSM exchange registry updates and control
messages without a separate per-agent HTTP API. `libvirtex_cluster` defines
Mnesia tables for VM requests, offers, placements, VM records, and hypervisor
reports; these records are written transactionally and replicated with
`disc_copies` on participating nodes. PostgreSQL remains CCM's relational store
for operator/audit data and durable workflow history, not the scheduling
registry.

Mnesia provides shared state, but it is neither a replacement for an HSM's
local admission ledger nor a safe reason to schedule during a partition. CCM
is the sole election authority: it uses a Mnesia transaction to change a
request from `open` to `elected` exactly once. HSMs watch eligible requests and
may make an offer only after creating an atomic, short-lived provisional
reservation in their own durable ledger.

1. CCM persists the VM request and publishes its generation, resources,
   capabilities, and affinity rules with an offer deadline. Only enabled,
   recently healthy HSMs matching required labels/capabilities consider it.
2. Each matching HSM evaluates observed libvirt usage plus committed and
   provisional reservations against its configured limits. It also evaluates
   workload affinity/anti-affinity from the request and its locally known VM
   placements. If eligible, it atomically records a held reservation and writes
   an idempotent offer to the registry; otherwise it may record a diagnostic
   rejection.
3. Several HSMs may offer for the same request. After the deadline, or once
   policy permits early election, CCM alone chooses one offer deterministically.
   The initial policy honors hard affinity, prefers lowest projected
   utilization, then uses a stable HSM ID tie-breaker. In one Mnesia
   transaction CCM records the elected HSM/offer; it then sends
   `CommitReservation` to that HSM. Unexpired losing offers remain held until
   IPAM succeeds or the request is terminal, enabling safe fallback.
4. Once the winner confirms its reservation, CCM requests an idempotent IPAM
   allocation from the elected hypervisor's configured subnet. It records the
   resulting lease with the HSM/subnet identity, then sends `EnsureVM` with the
   reservation ID, request generation, and assigned network address. On a
   successful allocation CCM releases all losing offers.
5. The elected HSM starts or resumes the VM's supervised VM Agent. The agent
   creates/reconciles the libvirt domain and reports its VM record, reservation,
   and observed resource state to Mnesia/CCM.
6. CCM marks the VM running only after confirmation. A failed workflow retries
   safely or compensates by releasing the IP lease and reservation. HSMs reclaim
   provisional offers on expiry, including when CCM is unavailable.

## IPAM Subnet-Exhaustion Fallback

If IPAM returns the classified `subnet_exhausted` outcome for the elected HSM,
CCM must not fail the VM request immediately. It appends an `IPAMAttempt`,
and transactionally records a `release_pending` fallback state while excluding
the exhausted subnet for that request generation. Its durable worker releases
the elected HSM reservation; only after that release is confirmed does CCM
reopen and elect the next valid, unexpired offer on a different subnet. This
remains a CCM decision even when multiple offers are present.

If no valid offer remains, CCM publishes a new generation carrying the excluded
subnets and collects fresh offers. It stops after a configured attempt/generation
limit and marks the request `failed_ipam_capacity`, releasing every remaining
offer. Do not globally drain a hypervisor merely because its subnet is full: it
may still host IP-less or different-network workloads. Transient, provider, and
authentication IPAM failures use retry/backoff and do not trigger a different
HSM election. The implementation plan and test matrix are in
[IPAM fallback election](ipam-fallback-election.md).

The provisional local hold is required: the shared registry prevents competing
work from being invisible, while only the HSM can prevent two simultaneous
offers/commands from overcommitting its host. `CommitReservation`, release,
and `EnsureVM` are idempotent by request ID and generation.

Each HSM owns a `DynamicSupervisor` for multiple independent VM Agents, one
per managed VM. A VM Agent owns its domain's ensure/delete/reconcile loop and
reports state transitions; HSM owns aggregate reservations and restart recovery.
The HSM recreates agents from its local/Mnesia VM records before accepting new
offers. Observed domains without a matching managed identity are reported but
do not consume scheduler reservations until an explicit import policy exists.
VM definitions carry the Libvirtex VM ID and placement generation in metadata
so retries cannot operate on the wrong guest.

## Service Interfaces and Deployment

Use `libcluster` for Erlang node discovery and cluster formation. Give every
CCM/HSM node a stable, unique long name (for example,
`hsm_hv_01@hv-01.example.net`) and a common secret distribution cookie supplied
at runtime. Configure a fixed, narrow Erlang distribution-port range and enable
TLS distribution before production use: the cookie authenticates nodes but does
not encrypt traffic. The infrastructure administrator is responsible for DNS
and reachability for EPMD (or the chosen EPMD-less alternative) and the
distribution-port range between all nodes.

`libvirtex_cluster` should use a static, inventory-derived libcluster topology
first; later it may add a provider-aware strategy as hypervisors are created.
It exposes a registry/watch interface to applications, reconnects after node
loss, and triggers full HSM/CCM state re-synchronization on rejoin. It must not
infer that a node is healthy simply because it is connected. The control service
still exposes HTTPS JSON for operators and automation, including VM requests,
inventory, agents, operations, and drain/enable actions.

Mnesia data directories must be persistent Podman mounts on CCM and every HSM;
never place `disc_copies` on a disposable container filesystem. Define table
copy and recovery strategy in Phase 0, including behavior when a node is
partitioned or loses its local copy. HSM must stop making offers if it cannot
reach the registry/election authority, while its local VM Agents continue
reconciliation for already committed VMs.

Run the CCM as a Podman container on the bastion, supervised by a generated
systemd unit. Give it persistent mounts only for required configuration and
TLS material. PostgreSQL runs as a separate, isolated Podman container on the
bastion with a dedicated local volume mounted at its data directory; this volume
is the durable database boundary and must be backed up by the administrator.
Because CCM uses host networking for distributed Erlang, it connects to
PostgreSQL through a loopback-only published database endpoint, never through
the flat hypervisor network. The Ansible `postgres` role manages the PostgreSQL
container; its volume must be retained across replacement and included in the
bastion backup policy.
Run it with `--network host`, like HSM, so its distributed Erlang node has a
stable, directly reachable address on the flat network. Do not expose its
operator HTTPS listener beyond the administrator-approved bastion interface.

Run each scheduler as a Podman container with `--network host`, a read-only
root filesystem where feasible, and only the minimum bind-mounted libvirt
socket needed for the chosen API. Treat the socket as privileged host control:
run a dedicated service account, limit image provenance, and do not mount broad
host paths or IPAM credentials. The bastion hosts the CCM container, PostgreSQL
access, backups, and deployment-platform supplied secrets.

Static inventory is imported from a versioned file or source adapter and
reconciled into the database. Auto-provisioning is opt-in: the scheduler asks
the provisioner only when no static candidate can fulfill a request, then
waits for the new host's authenticated agent registration before placement.

## Ansible Provisioning

Use Ansible to deploy or update CCM, HSM, and dedicated PostgreSQL Podman
containers with their systemd units. It does not provision hosts, networks,
KVM/libvirt, Podman, certificates, or other infrastructure, and it does not
bypass CCM to create scheduled VMs. The proposed inventory, roles, variables,
rollout order, and validation steps are specified in [the Ansible provisioning
design](ansible-provisioning.md). An HSM is available only after its container
joins the libcluster topology and reports healthy reconciliation to CCM.

## Failure Handling and Operations

HSM reports reservation creates/commits/releases, VM Agent state changes, and
observed libvirt-resource changes immediately, and also sends periodic
heartbeats with agent version, host capacity, observed use, reservation count,
and monotonic agent time. CCM uses these reports to maintain its fleet-wide
hypervisor tracker. Mark a host
`unreachable` after a configured missed-heartbeat interval, exclude it from new
offers, and keep existing VMs `unknown` until reconciliation. Never reclaim
running VM resources from central telemetry alone. Agent restart recovery
reloads local durable reservations and reconciles libvirt before offering
capacity.

Every external command needs an idempotency key, bounded retry with backoff,
and an auditable operation record. Record metrics for placement latency,
reservation rejections, heartbeat age, IPAM errors, reconciliation drift, and
per-host reserved versus observed resources. Structured logs must include VM,
operation, reservation, and hypervisor IDs.

## Delivery Plan

### Phase 0 — Contracts and foundations

Create `libvirtex_core`, define domain structs, state transitions, behaviours,
error taxonomy, and ExUnit contract tests. Add CI for `mix format
--check-formatted`, compile, test, and Dialyzer once types stabilize. Decide
the database schema, TLS-distribution configuration, libvirt connection method,
and the initial IPAM provider before implementation.

### Phase 1 — Single-host vertical slice

Implement the scheduler agent's libvirt observer, local reservation store,
and reconciliation loop. Implement a minimal control API with PostgreSQL,
static inventory, Mnesia registry, offer/election protocol, supervised VM
Agents, and an in-memory/fake subnet-aware IPAM adapter. Prove concurrent
offers, single CCM election, IP allocation from the elected HSM's subnet,
idempotent retry, delete, and reservation expiry against a test hypervisor.
This phase establishes the safety invariant: a host never accepts resources
beyond its configured limits.

### Phase 2 — Production control plane

Add Phoenix UI, authentication/authorization, audit history, HTTPS/TLS
distribution, durable operation workers, real IPAM adapter, cluster rejoin,
host drain, and failure dashboards. Test duplicate and delayed messages,
control-service restart at each workflow step, IPAM failure compensation,
network partition/rejoin, and agent restart recovery.

### Phase 3 — Fleet and provisioning

Support multiple agents, utilization-aware ranking, inventory source refresh,
and a provider-backed hypervisor provisioner. Add admission limits, provisioning
quotas, decommission/drain workflow, capacity reporting, and load/failure tests
at representative fleet size.

### Phase 4 — Advanced capacity policy

Add explicit, opt-in CPU and memory overcommit policies only after baseline
reservation correctness is established. Policies must be per-hypervisor or
host class, advertise separate physical and allocatable limits, and be visible
in offers, election, UI, audit events, and metrics. Never enable overcommit by
default or silently reinterpret existing RAM/vCPU requests.

## Acceptance Criteria for the First Release

- An operator can request and delete a VM through the control API; both calls
  are idempotent.
- A scheduler rejects requests that would exceed its configured RAM or vCPU
  capacity, even with stale central telemetry.
- Concurrent eligible HSMs can make offers for one request, but CCM commits
  exactly one winner and all losing provisional reservations expire or release.
- CCM allocates the VM address from the elected HSM's configured IPAM subnet;
  an IPAM failure leaves no committed reservation or leaked lease.
- On a classified subnet-exhaustion response, CCM releases the elected HSM and
  elects a valid offer on a different subnet before failing the request.
- Each managed VM has exactly one supervised VM Agent on its elected HSM; agent
  restart or HSM restart recovers from the VM record without creating a second
  domain.
- A successfully created VM has one recorded placement and one confirmed IPAM
  lease; failed workflows leave neither active reservation nor leaked lease.
- Scheduler and control-service restarts recover in-progress operations without
  duplicating a VM or consuming capacity twice.
- An unreachable or draining hypervisor receives no new placements, while its
  existing VMs remain visible as `unknown` or observed until recovered.
