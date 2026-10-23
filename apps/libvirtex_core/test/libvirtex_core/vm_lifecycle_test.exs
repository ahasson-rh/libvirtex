defmodule LibvirtexCore.VMLifecycleTest do
  use ExUnit.Case, async: true

  alias LibvirtexCore.{Error, VMLifecycle, Domain.VMRequest}

  test "allows the normal creation lifecycle" do
    request = %VMRequest{id: "vm-1", idempotency_key: "request-1", ram_bytes: 1, vcpus: 1}

    assert {:ok, %{lifecycle_state: :placing}} = VMLifecycle.transition(request, :placing)
    assert VMLifecycle.allowed?(:provisioning, :running)
  end

  test "rejects an unsafe lifecycle transition" do
    request = %VMRequest{id: "vm-1", idempotency_key: "request-1", ram_bytes: 1, vcpus: 1}

    assert {:error, %Error{category: :conflict, details: %{from: :requested, to: :running}}} =
             VMLifecycle.transition(request, :running)
  end
end
