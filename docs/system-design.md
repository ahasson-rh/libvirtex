# Libvirtex System Design and Delivery Plan

## Purpose and Scope

Libvirtex schedules libvirt VMs onto a configured inventory of hypervisors.
Each Hypervisor Scheduler Module (HSM) registers itself with the Command
Control Module (CCM) before it is eligible for placement. The system tracks
allocatable RAM and vCPUs, manages an IPAM lease per VM, and gives operators a
central web/API control plane.

The system is deliberately kept lightweight, not a general cluster orchestrator:
there is no VM live migration, distributed storage management, automatic VM rescheduling
after host loss, or multi-region consensus. 

## Operating Assumptions and Scope

The bastion and hypervisors are on an administrator-managed flat network.
Network reachability, routing, firewall policy, and the underlying bastion and
hypervisor infrastructure are the infrastructure administrator's
responsibility. CoreDNS is an assumed part of that infrastructure. Libvirtex
manages the VM IP-to-name records in the administrator-designated CoreDNS
zone, but does not provision or otherwise administer the CoreDNS service,
network, or zone delegation. Libvirtex assumes that CCM and every HSM can
reach each other over the configured authenticated control channel.

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
   |        +----------- CoreDNS Corefile record manager
   |
 libcluster / distributed Erlang / shared request registry
   |
HypervisorSchedulerModule (one per hypervisor, Podman --network host)
   |
DynamicSupervisor -> VM Agent (one per managed VM) -> libvirt local socket/API
                                                   |
                                                libvirtd ---- VMs
```

`CommandControlModule` is the source of truth for the loaded inventory, VM
desired state, workflow progress, placements, and IPAM lease references. CCM
receives the authoritative inventory-file path as configuration. Each
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
| `libvirtex_dns` | `DNSRecords` behaviour and adapters that inject/delete managed VM records in the CoreDNS Corefile | DNS service provisioning, zone delegation, or arbitrary Corefile configuration |

Start `libvirtex_core` as an independent app. Keep the IPAM and DNS apps
independent when adapters are expected to be reusable or have their own
dependencies; otherwise begin as implementations beneath the control module
and extract without changing the core behaviour contracts.

`libvirtex_cluster` is the single owner of cluster configuration. CCM and HSM
depend on it rather than each maintaining their own libcluster topology or
node-discovery rules. It also owns Mnesia startup, table definitions, and
rejoin synchronization.

## Domain Model

Persist immutable IDs and explicit state transitions. Core records are:

- `Hypervisor`: ID, inventory identity, address, enabled/draining state,
  allocatable limits, capabilities, IPAM subnet ID/prefix, agent identity, and
  last heartbeat. One enabled hypervisor maps to one IPAM allocation subnet.
- `VMRequest`: ID, caller/idempotency key, requested RAM/vCPUs, network/image
  specification, VM role (`master`, `worker`, or `infra`), workload ID,
  required/preferred host labels, workload-affinity or anti-affinity rules,
  desired state (`running` or `absent`), and lifecycle state.
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
- `DNSRecord`: VM request ID, fully qualified name, address, zone, provider
  reference, and lifecycle state. It is associated with the confirmed IP lease
  and stores no CoreDNS administration credentials.
- `VMRecord`: VM request ID, domain identity, elected HSM, reservation and
  lease references, role, workload ID, desired/observed state, and placement
  generation. It is owned locally by that VM's HSM agent and replicated as
  cluster state.
- `Operation`: durable workflow step, retry count, error, timestamps, and an
  idempotency key for every remote action. Later parallel processing also adds
  a request-generation ownership lease and worker identity.
- `IPAMAttempt`: request generation, HSM/subnet, idempotency key, outcome, and
  provider error category. `subnet_exhausted` is distinct from transient and
  authentication/provider errors.

Suggested lifecycle: `requested -> placing -> reserved -> ip_reserved ->
provisioning -> running`; after the VM is confirmed, CCM injects its DNS record
and marks it published. Failures move to `failed` after compensating release of
the DNS record, reservation, and unconfirmed lease as applicable. Deletion is
`deleting -> absent`: CCM removes the DNS record before releasing the address,
and records a retryable operation if removal cannot yet be confirmed. A running
VM whose agent disappears becomes `unknown`, not immediately deleted.

## VM Roles and Placement Topology

Every VM has exactly one role: `master`, `worker`, or `infra`. A request also
has a workload ID, allowing rules to target a subset of VMs belonging to the
same workload. Rules use explicit selectors such as a workload ID plus one or
more roles. `same_hypervisor` requires selected VMs to share a host;
`different_hypervisor` requires them to be on different hosts. For example, a
workload can colocate its `master` and `infra` VMs while requiring every
`worker` to be separate from `master`; any combination of the three roles can
be expressed by composing selectors and rules.

CCM validates contradictory rules before publishing a request. HSM evaluates
hard rules against committed placements and active offers from Mnesia, then
atomically records topology claims with its provisional resource reservation.
This prevents concurrent offers from bypassing anti-affinity. Soft preferences
may influence CCM's deterministic election score but never override a hard
constraint. When a request specifies no affinity or anti-affinity rule, it has
no topology constraint: every otherwise eligible hypervisor may offer, and CCM
uses its normal capacity/utilization election policy. Initial scope applies
rules within one workload; cross-workload selectors are a later extension.

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
   workload affinity/anti-affinity from the request and Mnesia placement
   records. If eligible, it atomically records a held resource/topology
   reservation and writes an idempotent offer to the registry; otherwise it may
   record a diagnostic rejection.
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

## CoreDNS Record Management

CCM owns the desired DNS record for every scheduled VM. Once an HSM confirms a
VM and its IP lease, CCM creates or reconciles the VM's configured FQDN-to-IP
mapping in CoreDNS. When a VM is retired, CCM removes that mapping before its
address is released for reuse. The record operation is part of the durable VM
workflow: it has an idempotency key, audit record, bounded retry, and explicit
success or failure state. A failed CoreDNS update must leave the VM and lease
intact for reconciliation rather than silently releasing an address that could
still be published.

`libvirtex_dns` defines a small `DNSRecords` behaviour, initially with
idempotent `inject_vm_record` and `delete_vm_record` operations. Both accept
the Libvirtex VM ID, FQDN, address, and zone; deletion also accepts the
provider record reference when one exists. The implementation owns only a
Libvirtex-managed section of the configured CoreDNS Corefile. It must preserve
administrator-managed configuration, serialize concurrent Corefile updates,
validate the resulting file with the CoreDNS binary, atomically install it,
and trigger the configured safe CoreDNS reload mechanism. Reconciliation lists
or derives the managed records and repairs drift without changing records
outside that section.

## Service Interfaces and Deployment

Use `libcluster` for Erlang node discovery and cluster formation. Give every
CCM/HSM node a stable, unique long name (for example,
`hsm_hv_01@hv-01.example.net`) and a common secret distribution cookie supplied
at runtime. Configure a fixed, narrow Erlang distribution-port range and enable
TLS distribution before production use: the cookie authenticates nodes but does
not encrypt traffic. The infrastructure administrator is responsible for DNS
and reachability for EPMD (or the chosen EPMD-less alternative) and the
distribution-port range between all nodes.

`libvirtex_cluster` uses a configured, inventory-derived libcluster topology.
An HSM authenticates and registers with CCM after joining that topology; CCM
matches the registration to the configured inventory and enables the HSM only
after its initial reconciliation and health report. It exposes a
registry/watch interface to applications, reconnects after node loss, and
triggers full HSM/CCM state re-synchronization on rejoin. It must not infer
that a node is healthy simply because it is connected. The control service
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
TLS material, including a read-only Podman volume that makes the inventory file
available at CCM's configured inventory-file path. PostgreSQL runs as a
separate, isolated Podman container on the
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

CCM receives the path to a versioned hypervisor inventory file through its
runtime configuration. Podman makes that file available to the CCM container
through a read-only volume mounted at the configured path. At startup CCM
validates the file and loads it as the authoritative inventory snapshot: within
one database transaction it overwrites the existing `Hypervisor` host entries
rather than merging or retaining entries from a previous file. The configured
file is therefore the sole mechanism for adding, changing, or removing hosts
from inventory.

Each host listed in that snapshot runs an HSM which authenticates and registers
itself with CCM. CCM records the registration identity, address, capabilities,
and initial reconciliation state against its loaded inventory entry. A
registered HSM becomes available for placement only after inventory validation
and a healthy reconciliation report. Dynamically provisioning or enrolling
unconfigured hypervisors is out of scope.

CoreDNS access is configured as a distinct infrastructure integration with the
least privilege needed to update the managed Corefile section and reload the
service. Its credentials and Corefile path are supplied as runtime secrets and
are never stored in `DNSRecord` or operation data. The infrastructure
administrator owns CoreDNS availability, zone configuration, backups, and the
initial managed-section marker; Libvirtex owns the contents between that
marker for VM records.

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
idempotent retry, delete, CoreDNS record injection/deletion, and reservation
expiry against a test hypervisor.
This phase establishes the safety invariant: a host never accepts resources
beyond its configured limits.

### Phase 2 — Production control plane

Add Phoenix UI, authentication/authorization, audit history, HTTPS/TLS
distribution, durable operation workers, real IPAM adapter, cluster rejoin,
host drain, and failure dashboards. Test duplicate and delayed messages,
control-service restart at each workflow step, IPAM failure compensation,
network partition/rejoin, and agent restart recovery.

### Phase 3 — VM roles and workload topology

Add the `master`, `worker`, and `infra` role model, workload IDs, selector-based
`same_hypervisor`/`different_hypervisor` rules, validation, and Mnesia topology
claims. Extend HSM admission so resource and hard-topology claims are one
atomic operation. Extend CCM election scoring with soft preferences and show
role/topology decisions in the UI and audit trail. Test all role combinations,
conflicting rules, concurrent offers, restart recovery, and IPAM fallback where
only a topology-valid alternate HSM may be elected.

### Phase 4 — Fleet operations

Support multiple agents, utilization-aware ranking, inventory source refresh,
and authenticated HSM self-registration. Add admission limits,
decommission/drain workflow, capacity reporting, and load/failure tests at
representative fleet size. Creating or provisioning hypervisors remains out of
scope.

### Phase 5 — Advanced capacity policy

Add explicit, opt-in CPU and memory overcommit policies only after baseline
reservation correctness is established. Policies must be per-hypervisor or
host class, advertise separate physical and allocatable limits, and be visible
in offers, election, UI, audit events, and metrics. Never enable overcommit by
default or silently reinterpret existing RAM/vCPU requests.

### Phase 6 — Parallel CCM request processing

Add a configurable, supervised CCM workflow-worker pool (for example, a
`DynamicSupervisor` of request workers) so independent VM requests can advance
in parallel. Before a worker performs an external action, it must acquire a
generation-scoped ownership lease in a Mnesia transaction and renew it while
active. A unique Mnesia transition from `open` to `elected` still makes CCM the
sole logical election authority even when multiple workers race for work; only
one worker can own or elect a particular request generation.

Workers must use existing idempotency keys for HSM/IPAM calls, record each
handoff/retry in `Operation`, and resume expired leases after a worker crash.
Bound the pool and external-call concurrency separately to protect IPAM and
HSMs. Load-test many independent requests, duplicate delivery, worker crash at
every workflow step, lease expiry, and concurrent attempts to elect the same
request. This phase introduces no parallelism within a single VM request's
state machine.

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
- Hard role-based affinity and anti-affinity rules are honored during both
  normal and IPAM-fallback election; an invalid alternate HSM is never chosen.
- A successfully created VM has one recorded placement and one confirmed IPAM
  lease, plus one managed CoreDNS mapping; failed workflows leave neither an
  active reservation nor a leaked lease or DNS record.
- Retiring a VM removes its CoreDNS mapping before its IP address becomes
  available for a new lease; retry/reconciliation repairs failed or drifted
  record updates without altering administrator-managed CoreDNS configuration.
- Scheduler and control-service restarts recover in-progress operations without
  duplicating a VM or consuming capacity twice.
- An unreachable or draining hypervisor receives no new placements, while its
  existing VMs remain visible as `unknown` or observed until recovered.
