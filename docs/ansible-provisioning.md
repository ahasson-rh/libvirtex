# Ansible Provisioning Design

## Purpose

Ansible deploys and maintains the Libvirtex service containers:

- **CommandControlModule (CCM):** the central Phoenix/API control plane in a
  Podman container on the bastion or other control host.
- **HypervisorSchedulerModule (HSM):** one host-networked Podman container on
  each libvirt hypervisor.
- **PostgreSQL:** a dedicated Podman container on the bastion, with a local
  persistent volume for its data directory.

Ansible deploys these containers and their systemd units. CCM remains
responsible for VM placement and lifecycle. A host is not schedulable merely
because its playbook completed: its HSM must join the `libcluster` Erlang
cluster and pass its first libvirt reconciliation.

## Assumptions and Non-Goals

The infrastructure administrator provides a flat, reachable network between
the bastion and all hypervisors, including DNS, routes, and firewall rules for
EPMD (or the selected EPMD-less transport), the configured Erlang distribution
port range, and the bastion's HTTPS endpoint. Ansible and Podman are assumed
to be preinstalled and functional on all target systems. Installing, validating,
or configuring KVM, libvirt, networking, storage, certificates, or other host
infrastructure is out of scope. PostgreSQL is the exception: Ansible deploys
its container and application data volume. Ansible must not attempt to
remediate the remaining prerequisites.

## Proposed Automation Layout

Keep automation under `infra/ansible/` once implementation begins:

```text
infra/ansible/
  inventories/{dev,stage,prod}/{hosts.yml,group_vars/,host_vars/}
  playbooks/{site.yml,postgres.yml,ccm.yml,hsm.yml,verify.yml,drain_hsm.yml}
  roles/{postgres,ccm,hsm}/
  collections/requirements.yml
```

Pin Ansible collections and container image digests in source control. Use
`containers.podman` for images, containers, and generated systemd units rather
than shelling out to Podman. CI should run `ansible-lint`, syntax checks, and a
non-production `--check` run against representative inventory.

## Inventory and Variables

Inventory groups describe operational role, not scheduling state:

```yaml
ccm:
  hosts:
    bastion-01:
      ansible_host: 192.0.2.10
hypervisors:
  hosts:
    hv-01:
      ansible_host: 192.0.2.21
      libvirtex_hypervisor_id: hv-01
      libvirtex_allocatable_ram_mib: 49152
      libvirtex_allocatable_vcpus: 24
      libvirtex_capabilities: ["kvm", "x86_64"]
```

Store environment-wide, non-secret settings in `group_vars`: image digest,
CCM public URL, Erlang node-name domain, static libcluster seed list,
distribution-port range, heartbeat interval, and log level. Put host-specific
capacity, labels, immutable HSM ID, IPAM subnet ID/prefix, and libvirt socket
choice in `host_vars`.
CCM imports the rendered hypervisor inventory via a signed or authenticated
endpoint; Ansible must never write directly to CCM's database.

Do not place database URLs, Erlang distribution cookies, passwords, private
keys, or IPAM tokens in plaintext inventory. Mount externally provisioned secret
files into the containers read-only, or use Ansible Vault strictly to render
the application-container configuration. Mark secret tasks `no_log: true`.
Ansible does not create, rotate, or distribute the secrets themselves.

## Container Deployment Boundary

There is intentionally no `common` or host-configuration role. The `postgres`,
`ccm`, and `hsm` roles may create their container, systemd unit, and
application-owned configuration/state directories only. They must not change
packages, users, libvirt, network/firewall rules, or certificates. A failed
host prerequisite should cause a clear deployment failure for the infrastructure
administrator to resolve.

## PostgreSQL Role

The `postgres` role runs first on the bastion. It creates a dedicated named or
explicit local Podman volume, mounts it at PostgreSQL's data directory, and
deploys a pinned PostgreSQL image with a systemd-managed Podman unit. The
volume is never removed by normal update, rollback, or teardown playbooks.

Publish PostgreSQL only on the bastion loopback interface so host-networked CCM
can connect while no hypervisor can reach it. Render the database name and
least-privilege CCM credentials from encrypted Ansible variables or externally
provided secret files; use `no_log: true` for these tasks. Run a local database
readiness probe before allowing CCM deployment. Backup scheduling and restore
testing must be explicit Ansible operational tasks targeting the persistent
volume; they must never depend on container-layer persistence.

## CCM Role

The `ccm` role deploys a pinned CCM image, externally supplied configuration
and secret mounts, and a systemd-managed Podman unit on the bastion. CCM
application state belongs in the Ansible-managed PostgreSQL container, not the
CCM filesystem; the CCM container may be replaced safely without losing
operations or inventory. Configure the loopback-only database endpoint, IPAM
adapter settings, public base URL, operator authentication, static libcluster
seed list, CCM node name, fixed distribution-port range, and distribution-cookie
file.

Mount a persistent Mnesia data directory for CCM. It holds its `disc_copies` of
the shared request, offer, placement, VM-record, and hypervisor-report tables;
it is distinct from PostgreSQL's database volume.

Run CCM with `--network host` so its distributed Erlang node is directly
reachable by HSMs. Keep the container unprivileged where host policy permits,
drop unnecessary capabilities, and mount configuration/secrets read-only.
Database migrations are a distinct, serialized CCM release action, performed
only after the infrastructure administrator has backed up the database. A CCM
health probe must verify the application, database, cluster membership, and
required IPAM-adapter configuration before deployment is declared healthy.

## HSM Role

The `hsm` role must:

1. Deploy a pinned HSM image and render configuration containing the immutable
   hypervisor ID, CCM endpoint, resource limits, labels, state directory, and
   libvirt-socket path.
2. Mount the externally provisioned distribution-cookie file and configure a
   unique HSM node name and the same fixed distribution-port range as CCM.
3. Create a Podman container with `--network host`, a persistent HSM state
   volume containing its Mnesia data and local reservation ledger, the minimal
   libvirt socket bind mount, `--read-only` where supported, dropped
   capabilities, and a systemd restart policy.
4. Start the service and wait for readiness, then verify that its node joined
   the libcluster topology and that CCM reports the same hypervisor ID healthy.

Host networking is required by the stated design, but it does not justify broad
privilege. Avoid `--privileged`, host PID namespaces, arbitrary host mounts, or
IPAM credentials in HSM. Restrict outbound network policy to CCM, required
image registries, and approved monitoring endpoints. The HSM's persistent
state must survive container recreation so reservation recovery can reconcile
after restart.

## Erlang Cluster Formation

All CCM/HSM containers use `libcluster` with a static, inventory-derived
topology in the first release. Ansible renders each container's stable long
node name, seed list, and distribution-port range, then mounts the common
distribution cookie supplied by the infrastructure administrator. CCM and HSM
must use host networking so the node names resolve and distribution connections
are directly reachable on the flat network.

The distribution cookie authenticates cluster members but does not encrypt
traffic. Production deployment therefore requires TLS distribution and the
administrator-managed network controls described above. Ansible only passes
the required settings/mounts into containers; it does not issue certificates,
open ports, or configure DNS. On rejoin, HSM synchronizes reservations and
observed capacity with CCM before making offers.

## Playbooks and Safe Rollout

`site.yml` applies `postgres`, CCM, and HSM roles in dependency order;
PostgreSQL must pass readiness before CCM deployment. Prefer these explicit
operational entry points:

- `postgres.yml`: deploy or upgrade PostgreSQL, retain its data volume, and
  verify local readiness before CCM is changed.
- `ccm.yml`: deploy or upgrade CCM, run the separately authorized serialized
  migration action, and validate the API and cluster before touching agents.
- `hsm.yml --limit hv-01`: bootstrap or upgrade a selected HSM. Use
  `serial: 1` initially; later use a conservative batch size with capacity
  headroom.
- `drain_hsm.yml --limit hv-01`: call CCM to mark the host draining, wait until
  it has no managed VMs/reservations, then stop or upgrade HSM. It must not
  force-stop guests.
- `verify.yml`: assert CCM health, libcluster membership, fresh heartbeats, and
  reservation/reconciliation status for every targeted host.

Before HSM upgrade, drain it through CCM. After restart, wait for registration
and reconciliation completion before clearing drain. Roll back by restoring the
previous pinned image digest and configuration, then repeat verification; do
not delete the HSM state volume as part of rollback.

## Provisioning New Hypervisors

The optional `libvirtex_provisioner` creates the underlying machine through a
provider-specific adapter. Once the provider returns an address, it must add
the host to the selected Ansible inventory source with its immutable ID,
capacity, and labels, then invoke the HSM bootstrap playbook. Treat host
creation and configuration as separate durable CCM operations with retry and
audit records. CCM enables the host for placement only after `verify.yml`
observes a trusted, healthy agent. Failed bootstrap leaves the host disabled;
the cleanup policy should be explicit rather than automatically destroying a
machine that might contain diagnostic state.

## Verification and Acceptance

For a new environment, validate: CCM HTTPS and database health; HSM libcluster
membership; HSM visibility of the local libvirt connection; correct allocatable
RAM/vCPU values in CCM; and a create/delete test VM using a test network/IPAM
allocation. Re-run the HSM role to prove idempotency, restart its container to
prove reservation recovery and cluster rejoin, and simulate an unreachable HSM
to confirm CCM excludes it from new placement. Record the image digests,
Ansible revision, inventory revision, and verification result in the deployment
audit.
