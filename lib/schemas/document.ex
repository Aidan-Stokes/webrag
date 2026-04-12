defmodule AONCrawler.Document do
  @moduledoc """
  Schema for storing raw and parsed document content from Archives of Nethys.

  This is the primary storage for crawled web pages before they are processed
  into chunks and embedded. It preserves both raw HTML for reprocessing and
  cleaned text for display.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :url, :string
    field :source, :string
    field :title, :string
    field :type, :string
    field :raw_html, :string
    field :text, :string
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          source: String.t() | nil,
          title: String.t() | nil,
          type: String.t() | nil,
          raw_html: String.t() | nil,
          text: String.t() | nil,
          processed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Creates a changeset for inserting a new document.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(document \\ %__MODULE__{}, attrs) do
    document
    |> cast(attrs, [:url, :source, :title, :type, :raw_html, :text])
    |> validate_required([:url])
    |> unique_constraint(:url)
  end

  @doc """
  Creates a changeset for updating an existing document.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(document, attrs) do
    document
    |> cast(attrs, [:title, :type, :raw_html, :text, :processed_at])
    |> validate_required([:url])
  end

  @doc """
  Returns true if the document has been processed.
  """
  @spec processed?(t()) :: boolean()
  def processed?(%__MODULE__{processed_at: nil}), do: false
  def processed?(%__MODULE__{}), do: true
end
