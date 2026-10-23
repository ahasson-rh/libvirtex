defmodule LibvirtexCore.Error do
  @moduledoc "A classified error returned by a Libvirtex boundary."

  @type category ::
          :validation
          | :conflict
          | :not_found
          | :unavailable
          | :timeout
          | :authentication
          | :provider
          | :subnet_exhausted
          | :unknown

  @type t :: %__MODULE__{
          category: category(),
          operation: atom() | nil,
          retryable?: boolean(),
          message: String.t(),
          details: map()
        }

  @enforce_keys [:category, :message]
  defstruct [:category, :operation, :message, retryable?: false, details: %{}]

  @spec new(category(), String.t(), keyword()) :: t()
  def new(category, message, options \\ []) when is_atom(category) and is_binary(message) do
    %__MODULE__{
      category: category,
      operation: Keyword.get(options, :operation),
      retryable?: Keyword.get(options, :retryable?, retryable?(category)),
      message: message,
      details: Keyword.get(options, :details, %{})
    }
  end

  @spec retryable?(category()) :: boolean()
  def retryable?(category) when category in [:unavailable, :timeout, :provider], do: true
  def retryable?(_category), do: false
end
