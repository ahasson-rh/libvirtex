defmodule LibvirtexCore.ProviderContractTest do
  use ExUnit.Case, async: true

  alias LibvirtexCore.{Behaviours.DNSRecords, Behaviours.IPAM, Domain.DNSRecord, Domain.IPLease}

  defmodule FakeIPAM do
    @behaviour IPAM

    @impl true
    def reserve(request) do
      {:ok,
       %IPLease{
         provider_ref: request.idempotency_key,
         address: "192.0.2.10",
         prefix: 24,
         vm_request_id: request.vm_request_id,
         hypervisor_id: request.hypervisor_id,
         subnet_id: request.subnet_id
       }}
    end

    @impl true
    def confirm(provider_ref), do: lookup(provider_ref)

    @impl true
    def release(_provider_ref), do: :ok

    @impl true
    def lookup(provider_ref) do
      {:ok,
       %IPLease{
         provider_ref: provider_ref,
         address: "192.0.2.10",
         prefix: 24,
         vm_request_id: "vm-1",
         hypervisor_id: "hsm-1",
         subnet_id: "subnet-1"
       }}
    end
  end

  defmodule FakeDNSRecords do
    @behaviour DNSRecords

    @impl true
    def inject_vm_record(record),
      do: {:ok, %{record | provider_ref: "coredns:vm-1", state: :published}}

    @impl true
    def delete_vm_record(_record), do: :ok
  end

  test "IPAM adapter implements the reserve, confirm, release, and lookup contract" do
    request = %{
      vm_request_id: "vm-1",
      hypervisor_id: "hsm-1",
      subnet_id: "subnet-1",
      idempotency_key: "operation-1"
    }

    assert {:ok, lease} = FakeIPAM.reserve(request)
    assert {:ok, %IPLease{provider_ref: "operation-1"}} = FakeIPAM.lookup(lease.provider_ref)
    assert {:ok, %IPLease{provider_ref: "operation-1"}} = FakeIPAM.confirm(lease.provider_ref)
    assert :ok = FakeIPAM.release(lease.provider_ref)
  end

  test "DNS adapter implements idempotent record injection and deletion" do
    record = %DNSRecord{
      vm_request_id: "vm-1",
      fqdn: "vm-1.example.test",
      address: "192.0.2.10",
      zone: "example.test"
    }

    assert {:ok, %DNSRecord{state: :published}} = FakeDNSRecords.inject_vm_record(record)
    assert :ok = FakeDNSRecords.delete_vm_record(record)
  end
end
