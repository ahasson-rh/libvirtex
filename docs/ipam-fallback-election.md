# IPAM Fallback Election Plan

## Goal

When IPAM cannot allocate an address from an elected HSM's subnet because the
range is exhausted, CCM must select another eligible HSM on a different subnet
without duplicating a VM, leaking an address, or holding capacity indefinitely.
CCM remains the sole authority that elects an offer.

## Phase 1 — Model and contracts

Add `ipam_subnet_id` to `Hypervisor`, `Placement`, and `IPLease`. Extend
`SchedulingRequest` with a generation, IPAM attempt count, excluded subnet IDs,
and a bounded fallback limit. Add `IPAMAttempt` with the elected HSM, subnet,
idempotency key, timestamp, and normalized outcome:
`allocated`, `subnet_exhausted`, `transient`, `unauthorized`, or `invalid`.

Extend the IPAM behaviour with `allocate(subnet_id, request_id, options)`. Its
provider adapter must classify a true address-pool exhaustion separately from
retriable provider failures. Add unit and contract tests for this mapping.

## Phase 2 — Election state machine

Implement Mnesia transactions for `open -> elected -> awaiting_ipam` and the
fallback transition. On `subnet_exhausted`, write the attempt record, release
the elected reservation through a durable `release_pending` operation, and add
its subnet to the generation exclusion set. Only after the HSM confirms release
may CCM return the request to election; never make an external HSM call inside
the Mnesia transaction.

Keep unexpired losing offers held until IPAM succeeds. CCM chooses the next
offer whose HSM subnet is not excluded; it must never self-elect a different
HSM. If no valid held offer remains, publish a fresh generation carrying the
exclusions and collect new offers. Release every hold when the request reaches
`provisioning` or a terminal state.

## Phase 3 — Workflow and recovery

Wire fallback into the CCM operation worker. Allocate addresses idempotently by
request generation and selected subnet. On crash or restart, replay the Mnesia
request and operation records: if a lease exists, continue with that placement;
if an exhaustion attempt is recorded, resume only eligible fallback election;
if outcome is unknown, query IPAM by idempotency key before retrying.

Apply bounded exponential backoff to `transient` outcomes. Fail immediately on
authorization or invalid-request outcomes, and fail as `failed_ipam_capacity`
after the configured fallback limit or after all eligible subnets are exhausted.
Emit an audit event for every election, release, attempt, and final outcome.

## Phase 4 — Tests and observability

Build a fake IPAM adapter with independently exhaustible subnets. Cover:

- Two offers on different subnets; first election exhausts and CCM elects the
  second HSM.
- Several HSMs on one exhausted subnet; CCM skips all of them for that
  generation.
- All eligible subnets exhausted; all reservations are released and no VM is
  created.
- IPAM success after fallback; exactly one lease, placement, VM Agent, and
  libvirt domain exist.
- CCM restart between IPAM failure, reservation release, and re-election.
- Duplicate IPAM callbacks and delayed HSM replies; no duplicate lease or VM.

Expose counters for allocation attempts, exhausted subnets, fallback elections,
fallback success/failure, reservation-release latency, and requests exhausted
by subnet. Include request ID, generation, HSM ID, subnet ID, and IPAM outcome
in structured logs.

## Rollout

Ship schema/read support first, then enable fallback behind a CCM feature flag.
Start with a low attempt limit and one test subnet in staging. Promote after
metrics confirm no stranded reservations or leaked leases. Keep the flag as an
emergency disable switch; disabled mode preserves the prior behavior of failing
cleanly after the first classified subnet-exhaustion response.
