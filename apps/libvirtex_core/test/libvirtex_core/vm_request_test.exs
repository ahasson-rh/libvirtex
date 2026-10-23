defmodule LibvirtexCore.Domain.VMRequestTest do
  use ExUnit.Case, async: true

  alias LibvirtexCore.{Error, Domain.VMRequest}

  test "creates a valid request" do
    attributes = %{
      id: "vm-1",
      idempotency_key: "request-1",
      ram_bytes: 1_073_741_824,
      vcpus: 2,
      role: :master
    }

    assert {:ok, %VMRequest{id: "vm-1", role: :master}} = VMRequest.new(attributes)
  end

  test "rejects invalid resources" do
    attributes = %{id: "vm-1", idempotency_key: "request-1", ram_bytes: 0, vcpus: 2}

    assert {:error,
            %Error{category: :validation, message: "ram_bytes must be a positive integer"}} =
             VMRequest.new(attributes)
  end
end
