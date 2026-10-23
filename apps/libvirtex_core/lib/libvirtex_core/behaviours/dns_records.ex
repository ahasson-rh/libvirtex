defmodule LibvirtexCore.Behaviours.DNSRecords do
  @moduledoc "Contract for the Libvirtex-managed CoreDNS record section."

  alias LibvirtexCore.{Error, Domain.DNSRecord}

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @callback inject_vm_record(DNSRecord.t()) :: result(DNSRecord.t())
  @callback delete_vm_record(DNSRecord.t()) :: :ok | {:error, Error.t()}
end
