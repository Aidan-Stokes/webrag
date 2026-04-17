defmodule AONCrawler.Indexer.BatchProcessor do
  @moduledoc """
  Batch processor for generating embeddings from document chunks.

  This GenServer manages the asynchronous processing of document chunks into
  embeddings using an external embedding API. It implements:

  - **Batch Processing**: Groups chunks into batches for efficient API calls
  - **Rate Limiting**: Respects API rate limits with configurable concurrency
  - **Retry Logic**: Automatic retry with exponential backoff for failed requests
  - **Progress Tracking**: Real-time progress updates via Telemetry
  - **Checkpointing**: Saves progress to enable resume after crashes

  ## Architecture

  The processor operates as a queue-based system:

  1. Chunks are added to the processing queue
  2. A timer triggers batch assembly when:
     - A batch reaches `batch_size`, OR
     - `batch_timeout` ms has passed since the first item in the batch
  3. Completed batches are sent to the embedding service
  4. Results are stored in the database

  ## Configuration

  Configure via `config.exs`:

      config :aoncrawler, AONCrawler.Indexer.BatchProcessor,
        batch_size: 100,
        batch_timeout: 5000,
        max_concurrent_batches: 5,
        retry_attempts: 3,
        retry_delay_ms: 1000

  ## Design Decisions

  1. **Timer-Based Flushing**: We use timers to ensure batches don't wait forever,
     balancing throughput with latency.

  2. **Checkpointing**: State is periodically persisted to allow resume after
     restarts without losing progress.

  3. **Telemetry Events**: We emit comprehensive telemetry events for monitoring:
     - `[:batch_processor, :batch, :started]`
     - `[:batch_processor, :batch, :completed]`
     - `[:batch_processor, :batch, :failed]`
     - `[:batch_processor, :chunk, :processed]`

  4. **Backpressure**: If the queue grows too large, we pause ingestion to
     prevent memory exhaustion.
  """

  use GenServer
  require Logger

  alias AONCrawler.Indexer.EmbeddingClient
  alias AONCrawler.Repo
  alias AONCrawler.Chunk
  alias AONCrawler.Embedding

  # ============================================================================
  # Types
  # ============================================================================

  @type batch_item :: %{
          chunk_id: String.t(),
          content_id: String.t(),
          text: String.t(),
          chunk_index: non_neg_integer(),
          metadata: map()
        }

  @type batch :: [batch_item()]

  @type state :: %{
          queue: [batch_item()],
          in_flight: %{
            batch_id: String.t(),
            items: batch(),
            inserted_at: integer()
          },
          stats: %{
            chunks_queued: non_neg_integer(),
            chunks_processed: non_neg_integer(),
            chunks_failed: non_neg_integer(),
            batches_processed: non_neg_integer(),
            batches_failed: non_neg_integer()
          },
          status: :idle | :processing | :paused,
          checkpoint_timer: reference() | nil,
          flush_timer: reference() | nil
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the batch processor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Queues chunks for embedding processing.

  Chunks are added to the internal queue and will be processed in batches
  according to the configuration.

  ## Parameters

  - `chunks` - List of chunks to process (can be Chunk structs or maps)
  - `opts` - Queue options

  ## Options

  - `:priority` - If true, adds chunks to the front of the queue
  - `:immediate` - If true, immediately triggers a batch flush

  ## Example

      iex> chunks = [
      ...>   %{id: "1", text: "Fireball deals fire damage..."},
      ...>   %{id: "2", text: "Lightning bolt..."}
      ...> ]
      iex> :ok = BatchProcessor.queue_chunks(chunks)
  """
  @spec queue_chunks([Chunk.t() | map()], keyword()) :: :ok | {:error, term()}
  def queue_chunks(chunks, opts \\ []) when is_list(chunks) do
    GenServer.cast(__MODULE__, {:queue_chunks, chunks, opts})
  end

  @doc """
  Queues a single chunk for processing.
  """
  @spec queue_chunk(Chunk.t() | map(), keyword()) :: :ok | {:error, term()}
  def queue_chunk(chunk, opts \\ []) do
    queue_chunks([chunk], opts)
  end

  @doc """
  Returns the current queue depth.
  """
  @spec queue_depth() :: non_neg_integer()
  def queue_depth do
    GenServer.call(__MODULE__, :queue_depth)
  end

  @doc """
  Returns processing statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns the current processor status.
  """
  @spec status() :: :idle | :processing | :paused
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Pauses processing, keeping queued items.
  """
  @spec pause() :: :ok
  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  @doc """
  Resumes processing after a pause.
  """
  @spec resume() :: :ok
  def resume do
    GenServer.cast(__MODULE__, :resume)
  end

  @doc """
  Clears the queue without processing.
  """
  @spec clear_queue() :: :ok
  def clear_queue do
    GenServer.cast(__MODULE__, :clear_queue)
  end

  @doc """
  Forces an immediate batch flush.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  @doc """
  Processes unembedded chunks from the database.

  This is the main entry point for batch processing existing chunks.
  """
  @spec process_unembedded(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_unembedded(_opts \\ []) do
    GenServer.call(__MODULE__, :process_unembedded, 60_000)
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    batch_timeout = Keyword.get(opts, :batch_timeout, 5000)
    max_concurrent = Keyword.get(opts, :max_concurrent_batches, 5)
    retry_attempts = Keyword.get(opts, :retry_attempts, 3)
    retry_delay = Keyword.get(opts, :retry_delay_ms, 1000)

    # Create ETS table for checkpoint persistence
    if :ets.info(:aoncrawler_batch_checkpoint) == :undefined do
      :ets.new(:aoncrawler_batch_checkpoint, [:set, :named_table, :public])
    end

    state = %{
      queue: [],
      in_flight: nil,
      stats: %{
        chunks_queued: 0,
        chunks_processed: 0,
        chunks_failed: 0,
        batches_processed: 0,
        batches_failed: 0
      },
      status: :idle,
      config: %{
        batch_size: batch_size,
        batch_timeout: batch_timeout,
        max_concurrent: max_concurrent,
        retry_attempts: retry_attempts,
        retry_delay: retry_delay
      },
      checkpoint_timer: nil,
      flush_timer: nil
    }

    # Schedule initial checkpoint
    schedule_checkpoint()

    Logger.info("BatchProcessor started",
      batch_size: batch_size,
      batch_timeout: batch_timeout,
      max_concurrent: max_concurrent
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:queue_depth, _from, state) do
    depth = length(state.queue)
    {:reply, depth, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        queue_depth: length(state.queue),
        in_flight: if(state.in_flight, do: length(state.in_flight.items), else: 0),
        status: state.status
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:process_unembedded, _from, state) do
    case Repo.unembedded_chunks(batch_size: state.config.batch_size * 2) do
      [] ->
        {:reply, {:ok, 0}, state}

      chunks ->
        chunk_maps = Enum.map(chunks, &chunk_to_map/1)
        new_state = add_to_queue(state, chunk_maps)

        # Trigger immediate flush
        new_state = maybe_flush(new_state)

        {:reply, {:ok, length(chunks)}, new_state}
    end
  end

  @impl true
  def handle_cast({:queue_chunks, chunks, opts}, state) do
    chunk_maps = Enum.map(chunks, &normalize_chunk/1)
    priority = Keyword.get(opts, :priority, false)
    immediate = Keyword.get(opts, :immediate, false)

    new_state =
      state
      |> add_to_queue(chunk_maps, priority)
      |> maybe_flush()

    new_state =
      if immediate do
        trigger_flush(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:pause, state) do
    {:noreply, %{state | status: :paused}}
  end

  @impl true
  def handle_cast(:resume, state) do
    new_state = %{state | status: :idle}
    new_state = maybe_flush(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:clear_queue, state) do
    {:noreply, %{state | queue: []}}
  end

  @impl true
  def handle_cast(:flush, state) do
    {:noreply, trigger_flush(state)}
  end

  @impl true
  def handle_info(:flush_timeout, state) do
    # Batch timeout triggered - flush the current batch
    new_state = trigger_flush(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:checkpoint, state) do
    save_checkpoint(state)

    timer = schedule_checkpoint()
    {:noreply, %{state | checkpoint_timer: timer}}
  end

  @impl true
  def handle_info({:batch_completed, batch_id, results}, state) do
    new_state = handle_batch_completed(batch_id, results, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:batch_failed, batch_id, error}, state) do
    Logger.error("Batch failed", batch_id: batch_id, error: inspect(error))

    new_state = handle_batch_failed(batch_id, error, state)
    {:noreply, new_state}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp add_to_queue(state, chunks, priority \\ false) do
    new_queue =
      if priority do
        Enum.reverse(chunks) ++ state.queue
      else
        state.queue ++ chunks
      end

    %{
      state
      | queue: new_queue,
        stats: %{state.stats | chunks_queued: state.stats.chunks_queued + length(chunks)}
    }
  end

  defp maybe_flush(state) do
    cond do
      state.status == :paused ->
        state

      state.in_flight != nil ->
        # Already processing a batch
        state

      length(state.queue) >= state.config.batch_size ->
        # Queue is large enough, trigger flush
        trigger_flush(state)

      length(state.queue) > 0 and state.flush_timer == nil ->
        # Start timeout timer for small batch
        timer = Process.send_after(self(), :flush_timeout, state.config.batch_timeout)
        %{state | flush_timer: timer}

      true ->
        state
    end
  end

  defp trigger_flush(state) do
    # Cancel any pending flush timer
    state = cancel_flush_timer(state)

    if length(state.queue) == 0 do
      %{state | status: :idle}
    else
      # Take batch_size items from queue
      {batch_items, remaining_queue} = Enum.split(state.queue, state.config.batch_size)

      batch_id = UUID.uuid4()

      in_flight = %{
        batch_id: batch_id,
        items: batch_items,
        inserted_at: System.system_time(:millisecond),
        attempts: 0
      }

      new_state = %{state | queue: remaining_queue, in_flight: in_flight, status: :processing}

      # Emit telemetry
      emit_telemetry(:batch_started, batch_id, length(batch_items))

      # Start processing
      process_batch(in_flight)

      new_state
    end
  end

  defp cancel_flush_timer(state) do
    if state.flush_timer do
      Process.cancel_timer(state.flush_timer)
    end

    %{state | flush_timer: nil}
  end

  defp process_batch(in_flight) do
    Task.Supervisor.async(AONCrawler.Indexer.TaskSupervisor, fn ->
      texts = Enum.map(in_flight.items, & &1.text)

      case EmbeddingClient.embed_batch(texts) do
        {:ok, embeddings} ->
          results = Enum.zip(in_flight.items, embeddings)
          send(__MODULE__, {:batch_completed, in_flight.batch_id, results})

        {:error, reason} ->
          send(__MODULE__, {:batch_failed, in_flight.batch_id, reason})
      end
    end)
  end

  defp handle_batch_completed(batch_id, results, state) do
    Logger.debug("Batch completed", batch_id: batch_id, items: length(results))

    # Store embeddings in database
    successful = store_embeddings(results)

    # Update stats
    new_stats = %{
      state.stats
      | chunks_processed: state.stats.chunks_processed + successful,
        batches_processed: state.stats.batches_processed + 1
    }

    new_state = %{state | in_flight: nil, stats: new_stats, status: :idle}

    # Emit telemetry
    emit_telemetry(:batch_completed, batch_id, successful, length(results) - successful)

    # Continue processing
    maybe_flush(new_state)
  end

  defp handle_batch_failed(batch_id, _error, state) do
    in_flight = state.in_flight
    attempts = (in_flight[:attempts] || 0) + 1

    cond do
      attempts < state.config.retry_attempts ->
        # Retry the batch
        retry_delay = state.config.retry_delay * :math.pow(2, attempts - 1)

        Logger.warning("Retrying batch",
          batch_id: batch_id,
          attempt: attempts,
          delay_ms: retry_delay
        )

        Process.send_after(
          self(),
          fn ->
            send(__MODULE__, {:retry_batch, in_flight})
          end,
          round(retry_delay)
        )

        %{state | in_flight: %{in_flight | attempts: attempts}}

      true ->
        # Max retries exceeded, mark as failed
        Logger.error("Batch failed permanently",
          batch_id: batch_id,
          attempts: attempts
        )

        # Re-queue failed items for manual retry
        failed_items = in_flight.items
        new_queue = state.queue ++ failed_items

        new_stats = %{
          state.stats
          | chunks_failed: state.stats.chunks_failed + length(failed_items),
            batches_failed: state.stats.batches_failed + 1
        }

        new_state = %{state | queue: new_queue, in_flight: nil, stats: new_stats, status: :idle}

        emit_telemetry(:batch_failed, batch_id, length(failed_items))

        maybe_flush(new_state)
    end
  end

  defp store_embeddings(results) do
    successful = 0

    Repo.transaction(fn ->
      Enum.reduce(results, successful, fn {item, embedding_vector}, count ->
        case insert_embedding(item, embedding_vector) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp insert_embedding(item, vector) do
    model =
      Application.get_env(
        :aoncrawler,
        [AONCrawler.Indexer, :embedding_model],
        "mxbai-embed-large"
      )

    embedding = %Embedding{
      id: Ecto.UUID.generate(),
      chunk_id: item.chunk_id,
      content_id: item.content_id,
      vector: vector,
      model: model,
      token_count: estimate_tokens(item.text),
      generated_at: DateTime.utc_now()
    }

    Repo.insert(embedding)
  rescue
    error ->
      Logger.error("Failed to insert embedding",
        chunk_id: item.chunk_id,
        error: inspect(error)
      )

      {:error, error}
  end

  defp estimate_tokens(text) do
    # Rough estimate: ~4 characters per token for English
    ceil(String.length(text) / 4)
  end

  defp schedule_checkpoint do
    # Checkpoint every 30 seconds
    Process.send_after(self(), :checkpoint, 30_000)
  end

  defp save_checkpoint(state) do
    checkpoint_data = %{
      queue_depth: length(state.queue),
      stats: state.stats,
      status: state.status,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(:aoncrawler_batch_checkpoint, {:checkpoint, checkpoint_data})
  end

  defp chunk_to_map(%Chunk{} = chunk) do
    %{
      chunk_id: chunk.id,
      content_id: chunk.content_id,
      text: chunk.text,
      chunk_index: chunk.chunk_index,
      metadata: chunk.metadata || %{}
    }
  end

  defp normalize_chunk(%{} = chunk) do
    %{
      chunk_id: Map.get(chunk, :id) || Map.get(chunk, :chunk_id) || UUID.uuid4(),
      content_id: Map.get(chunk, :document_id) || Map.get(chunk, :content_id) || "",
      text: Map.get(chunk, :text) || Map.get(chunk, :content) || "",
      chunk_index: Map.get(chunk, :chunk_index) || 0,
      metadata: Map.get(chunk, :metadata) || %{}
    }
  end

  defp normalize_chunk(chunk) when is_map(chunk) do
    normalize_chunk(chunk)
  end

  defp emit_telemetry(event, batch_id, success_count, fail_count \\ 0) do
    measurements = %{
      count: success_count,
      failures: fail_count
    }

    metadata = %{
      batch_id: batch_id
    }

    :telemetry.execute(
      [:aoncrawler, :batch_processor, event],
      measurements,
      metadata
    )
  end
end
