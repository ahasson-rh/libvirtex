defmodule LibvirtexCore.Domain.VMRequest do
  @moduledoc "The desired VM and its lifecycle state."

  alias LibvirtexCore.Error

  @enforce_keys [:id, :idempotency_key, :ram_bytes, :vcpus]
  defstruct [
    :id,
    :idempotency_key,
    :workload_id,
    :network,
    :image,
    :failure,
    ram_bytes: nil,
    vcpus: nil,
    role: :worker,
    desired_state: :running,
    lifecycle_state: :requested,
    required_host_labels: %{},
    preferred_host_labels: %{},
    topology_rules: []
  ]

  @type role :: :master | :worker | :infra
  @type desired_state :: :running | :absent

  @type lifecycle_state ::
          :requested
          | :placing
          | :reserved
          | :ip_reserved
          | :provisioning
          | :running
          | :unknown
          | :deleting
          | :absent
          | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          idempotency_key: String.t(),
          ram_bytes: pos_integer(),
          vcpus: pos_integer(),
          role: role(),
          desired_state: desired_state(),
          lifecycle_state: lifecycle_state(),
          workload_id: String.t() | nil,
          network: map() | nil,
          image: map() | nil,
          failure: Error.t() | nil,
          required_host_labels: map(),
          preferred_host_labels: map(),
          topology_rules: [map()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attributes) when is_map(attributes) do
    request = struct(__MODULE__, attributes)

    with :ok <- validate_required_string(request.id, :id),
         :ok <- validate_required_string(request.idempotency_key, :idempotency_key),
         :ok <- validate_positive_integer(request.ram_bytes, :ram_bytes),
         :ok <- validate_positive_integer(request.vcpus, :vcpus),
         :ok <- validate_member(request.role, [:master, :worker, :infra], :role),
         :ok <- validate_member(request.desired_state, [:running, :absent], :desired_state) do
      {:ok, request}
    end
  end

  defp validate_required_string(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp validate_required_string(_value, field),
    do: {:error, Error.new(:validation, "#{field} must be a non-empty string")}

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(_value, field),
    do: {:error, Error.new(:validation, "#{field} must be a positive integer")}

  defp validate_member(value, allowed, field) do
    if value in allowed do
      :ok
    else
      {:error, Error.new(:validation, "#{field} has an invalid value")}
    end
  end
end
