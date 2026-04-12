defmodule AONCrawler.Types.RuleContent do
  @moduledoc """
  Represents parsed content from Archives of Nethys.
  """
  @derive Jason.Encoder
  defstruct [
    :id,
    :type,
    :name,
    :raw_html,
    :text,
    :source_url,
    :metadata,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          name: String.t(),
          raw_html: String.t() | nil,
          text: String.t(),
          source_url: String.t(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end

defmodule AONCrawler.Types.Chunk do
  @moduledoc """
  Represents a text chunk ready for embedding.
  """
  @derive Jason.Encoder
  defstruct [
    :id,
    :content_id,
    :text,
    :chunk_index,
    :total_chunks,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          content_id: String.t(),
          text: String.t(),
          chunk_index: non_neg_integer(),
          total_chunks: pos_integer(),
          metadata: map() | nil
        }
end

defmodule AONCrawler.Types.Embedding do
  @moduledoc """
  Represents an embedding vector with metadata.
  """
  @derive Jason.Encoder
  defstruct [
    :id,
    :chunk_id,
    :content_id,
    :vector,
    :model,
    :token_count,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          chunk_id: String.t(),
          content_id: String.t(),
          vector: [float()],
          model: String.t(),
          token_count: non_neg_integer(),
          inserted_at: DateTime.t() | nil
        }
end

defmodule AONCrawler.Types.SearchResult do
  @moduledoc """
  Represents a search result with relevance scoring.
  """
  @derive Jason.Encoder
  defstruct [
    :content,
    :chunk,
    :embedding,
    :score,
    :rank
  ]

  @type t :: %__MODULE__{
          content: map() | nil,
          chunk: AONCrawler.Types.Chunk.t() | nil,
          embedding: AONCrawler.Types.Embedding.t() | nil,
          score: float(),
          rank: pos_integer()
        }
end

defmodule AONCrawler.Types.LLMRequest do
  @moduledoc """
  Represents a request to the LLM.
  """
  @derive Jason.Encoder
  defstruct [
    :query,
    :contexts,
    :system_prompt,
    :model,
    :temperature,
    :max_tokens,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          query: String.t(),
          contexts: [AONCrawler.Types.SearchResult.t()],
          system_prompt: String.t(),
          model: String.t(),
          temperature: float(),
          max_tokens: pos_integer(),
          inserted_at: DateTime.t() | nil
        }
end

defmodule AONCrawler.Types.LLMResponse do
  @moduledoc """
  Represents a response from the LLM.
  """
  @derive Jason.Encoder
  defstruct [
    :text,
    :model,
    :finish_reason,
    :usage,
    :sources,
    :latency_ms,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t(),
          finish_reason: String.t() | nil,
          usage: map(),
          sources: [String.t()],
          latency_ms: non_neg_integer(),
          inserted_at: DateTime.t() | nil
        }
end

defmodule AONCrawler.Types.CrawlJob do
  @moduledoc """
  Represents a crawl job for tracking.
  """
  @derive Jason.Encoder
  defstruct [
    :id,
    :url,
    :content_type,
    :status,
    :priority,
    :attempts,
    :max_attempts,
    :error_message,
    :response_hash,
    :inserted_at,
    :updated_at,
    :completed_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          content_type: atom() | nil,
          status: atom(),
          priority: non_neg_integer(),
          attempts: non_neg_integer(),
          max_attempts: pos_integer(),
          error_message: String.t() | nil,
          response_hash: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }
end

defmodule AONCrawler.Types.Query do
  @moduledoc """
  Represents a user query with options.
  """
  @derive Jason.Encoder
  defstruct [
    :text,
    :content_types,
    :top_k,
    :min_score,
    :filters
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          content_types: [atom()] | nil,
          top_k: pos_integer(),
          min_score: float(),
          filters: map() | nil
        }
end
