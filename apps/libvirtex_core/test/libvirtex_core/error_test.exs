defmodule LibvirtexCore.ErrorTest do
  use ExUnit.Case, async: true

  alias LibvirtexCore.Error

  test "classifies transient provider failures as retryable" do
    assert %Error{retryable?: true} = Error.new(:provider, "provider unavailable")
  end

  test "classifies exhausted subnets as a non-retryable outcome" do
    assert %Error{category: :subnet_exhausted, retryable?: false} =
             Error.new(:subnet_exhausted, "subnet has no free addresses")
  end
end
