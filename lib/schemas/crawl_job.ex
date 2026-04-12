defmodule AONCrawler.CrawlJob do
  @moduledoc """
  Schema for tracking crawl job state and history.

  Each crawl job represents a URL that needs to be (or has been) crawled.
  Jobs track their status through the crawling process and maintain
  history for monitoring and debugging purposes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "crawl_jobs" do
    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:job_type, :string, default: "incremental")
    field(:error_message, :string)
    field(:attempt_count, :integer, default: 0)
    field(:completed_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          status: String.t(),
          job_type: String.t() | nil,
          error_message: String.t() | nil,
          attempt_count: non_neg_integer(),
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @statuses ~w(pending in_progress completed failed cancelled)

  @doc """
  Creates a changeset for inserting a new crawl job.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(job \\ %__MODULE__{}, attrs) do
    job
    |> cast(attrs, [:url, :status, :job_type, :error_message, :attempt_count])
    |> validate_required([:url])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:job_type, ~w(incremental full))
  end

  @doc """
  Creates a changeset for updating a job's status.
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :error_message, :completed_at])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Returns true if the job has completed (success or failure).
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}) when status in ~w(completed failed cancelled),
    do: true

  def finished?(_), do: false
end
