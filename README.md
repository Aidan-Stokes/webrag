# WebRAG

A multi-source web crawler for building RAG (Retrieval-Augmented Generation) datasets from any website.

## What It Does

WebRAG discovers and crawls URLs from configured or custom sources, extracts content, generates embeddings, and enables semantic search. It supports:

- **Multiple sources**: Pre-configured sources or define your own
- **Scope control**: Only crawls URLs within allowed domains, preventing accidental crawling of unrelated sites
- **Parallel processing**: Concurrent crawling with configurable worker count (auto-detects CPU threads)
- **Progress tracking**: Real-time progress bars for all pipeline stages
- **Protocol Buffers**: Fast binary serialization for production pipelines
- **RAG pipeline**: Extracts text, chunks content, generates embeddings, and enables semantic search

## Installation

```bash
# Clone the repository
git clone https://github.com/your-org/webrag.git
cd webrag

# Install dependencies
mix deps.get

# Compile Protocol Buffer schemas
mix compile
```

## Pipeline

WebRAG uses a separate command for each stage of the pipeline:

```bash
mix discover    # 1. Find all URLs within scope
mix crawl       # 2. Crawl discovered URLs
mix index       # 3. Chunk documents
mix embed       # 4. Generate vector embeddings
mix compact     # 5. Export .pb files to JSON for debugging
mix query "?"   # 6. Semantic search
mix sync        # 7. Run discover + crawl + index + embed
mix shell       # 8. Interactive search shell
```

## Commands

### `mix discover`

Discovers URLs from configured or custom sources.

```bash
mix discover [options]
```

| Option | Description |
|--------|-------------|
| `--source <name>` | Source ID from config. Use `all` for all configured sources. Defaults to first source. |
| `--base-url <url>` | Base URL for a custom source. Use with `--domains`. |
| `--domains <domains>` | Comma-separated allowed domains (required for custom source). |
| `--name <name>` | Human-readable name for custom source. |
| `--seed <url>` | Starting URL(s). Can be repeated. |

#### Examples

```bash
# Discover from configured source
mix discover --source archives_of_nethys

# Discover from all configured sources
mix discover --source all

# Custom source with scope control
mix discover --base-url https://example.com --domains example.com,www.example.com
```

### `mix crawl`

Crawls discovered URLs and extracts content with real-time progress tracking.

```bash
mix crawl [options]
```

| Option | Description |
|--------|-------------|
| `--source <name>` | Source ID from config. Defaults to first source. |
| `--max <n>` | Maximum pages to crawl. Default: unlimited. |
| `--verbose` | Show all log messages (warnings, retries). |

#### Examples

```bash
# Crawl discovered URLs
mix crawl --source archives_of_nethys

# Limit to 1000 pages
mix crawl --source archives_of_nethys --max 1000
```

### `mix compact`

Exports Protocol Buffer files to JSON for debugging.

```bash
mix compact
```

Reads `.pb` files and writes human-readable `.json` files for inspection.

### `mix index`

Chunks documents into smaller pieces for embedding.

```bash
mix index [options]
```

| Option | Description |
|--------|-------------|
| `--chunk-size <n>` | Maximum characters per chunk. Default: 1000. |
| `--overlap <n>` | Character overlap between chunks. Default: 100. |
| `--only-new` | Only index documents not already chunked. |

#### Examples

```bash
# Index with defaults
mix index

# Custom chunk settings
mix index --chunk-size 500 --overlap 50

# Incremental (only new documents)
mix index --only-new
```

### `mix embed`

Generates vector embeddings for indexed chunks with batched parallel processing and progress tracking.

```bash
mix embed [options]
```

| Option | Description |
|--------|-------------|
| `--batch-size <n>` | Number of embeddings per batch. Default: 20. |
| `--only-missing` | Only embed chunks without existing embeddings. |

#### Examples

```bash
# Generate embeddings
mix embed

# Larger batches
mix embed --batch-size 256

# Incremental (only new chunks)
mix embed --only-missing
```

### `mix query`

Performs semantic search and generates an LLM response.

```bash
mix query "<question>" [options]
```

| Option | Description |
|--------|-------------|
| `--top <n>` | Number of results to return. Default: 5. |
| `--source <domain>` | Filter by source domain. |

#### Examples

```bash
mix query "How does Shove work?"
mix query "What is the dwarf language?" --top 10 --source archivesofnethys.com
```

### `mix sync`

Runs the complete pipeline: discover + crawl + index + embed in one command.

```bash
mix sync [options]
```

| Option | Description |
|--------|-------------|
| `--source <name>` | Source ID from config. |
| `--max <n>` | Maximum pages to crawl. |
| `--chunk-size <n>` | Maximum characters per chunk. |
| `--batch-size <n>` | Number of embeddings per batch. |
| `--only-new` | Only crawl new URLs not already indexed. |

#### Examples

```bash
# Full sync for a source
mix sync --source archives_of_nethys --max 5000

# Incremental sync (only new content)
mix sync --source archives_of_nethys --only-new
```

### `mix shell`

Interactive search shell with commands for exploring your RAG dataset.

```bash
mix shell [options]
```

| Command | Description |
|---------|-------------|
| `:help` | Show available commands |
| `:stats` | Show statistics (chunks, embeddings, sources) |
| `:sources` | List available sources |
| `:top <n>` | Show top N chunks by size |
| `:history` | Show search history |
| Enter | Run search with current query |
| Ctrl+C | Exit shell |

Press Enter after searching to generate an LLM answer.

#### Examples

```bash
mix shell
:stats
:source archives_of_nethys
:top 20
Who is the king of the realm?
```

## Adding Custom Sources

### Via Configuration

Add to `config/sources.exs`:

```elixir
config :webrag, :sources,
  my_source: %{
    name: "My Custom Source",
    base_url: "https://docs.example.com",
    allowed_domains: ["example.com", "docs.example.com"],
    seed_urls: ["https://docs.example.com/"],
    rate_limit: 5,
    user_agent: "WebRAG/1.0"
  }
```

### Via CLI (Runtime)

```bash
mix discover --base-url https://example.com --domains example.com
```

## Configuration

Edit `config/config.exs` or use environment variables:

```elixir
config :webrag,
  max_concurrent: System.schedulers_online()

config :webrag, WebRAG.Indexer,
  embedding_model: "mxbai-embed-large",
  embedding_dimensions: 1024,
  batch_size: 100,
  max_concurrent_batches: System.schedulers_online()
```

Override via environment:

```bash
MAX_CONCURRENT=16 mix discover
```

## Features

### Content Extraction

WebRAG uses a text-density algorithm as fallback for pages that don't match hardcoded selectors:
- Analyzes text block density to find main content
- Falls back to text density when specific selectors fail
- Works across diverse website structures

### Vector Search

The VectorStore provides efficient in-memory search:
- Cosine similarity for semantic search
- Source filtering at query time
- Query embedding cache with 60s TTL
- HNSW-ready architecture for 100k+ scale

### Hybrid Search

Combines semantic and fuzzy matching:
- Vector similarity for semantic search
- Levenshtein distance for keyword matching
- Score-weighted combination of both
- Early termination for performance

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        mix discover                         │
│  - Parallel URL discovery (up to CPU threads)              │
│  - ETS table for deduplication                            │
│  - Scope filtering by allowed_domains                     │
│  - --only-new flag for incremental updates                │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix crawl                           │
│  - Parallel crawling (up to CPU threads)                  │
│  - Content extraction with Floki                           │
│  - Rate limiting per host                                  │
│  - Skips already-crawled URLs                              │
│  - Filters invalid URLs (JavaScript, emails, etc.)         │
│  - Real-time progress bar                                   │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix index                           │
│  - Reads documents.pb                                      │
│  - Chunks documents                                        │
│  - Writes chunks.json + chunks.pb                          │
│  - --only-new flag for incremental updates                │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix embed                          │
│  - Parallel embedding generation                           │
│  - Batch API calls                                        │
│  - Writes embeddings.json + embeddings.pb                  │
│  - Real-time progress bar                                  │
│  - --only-missing flag for incremental updates            │
└────────────────────────��────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                      VectorStore (ETS)                      │
│  - In-memory vector search with cosine similarity            │
│  - Source filtering at query time                         │
│  - Query embedding cache (60s TTL)                        │
│  - HNSW-ready for 100k+ scale                              │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix query                           │
│  - Hybrid search (semantic + fuzzy)                        │
│  - Source filtering                                       │
│  - Levenshtein distance fuzzy matching                     │
│  - Context injection into LLM                              │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix sync                           │
│  - Runs discover + crawl + index + embed                   │
│  - --only-new for incremental updates                       │
│  - Progress tracking for all phases                       │
└─────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         mix shell                           │
│  - Interactive search shell                                │
│  - Commands: :help, :stats, :source, :top, :history       │
│  - Press Enter for LLM answer generation                   │
│  - Colored output with score breakdown                     │
└─────────────────────────────────────────────────────────────┘
```

## Scope Control

WebRAG enforces strict scope boundaries to prevent crawling unrelated sites or the entire internet.

### How It Works

When discovering URLs from a source, WebRAG:

1. **Extracts all links** from each page (including external links)
2. **Filters by allowed domains** - only URLs matching the configured domains are kept
3. **Reports filtered count** - shows how many URLs were blocked

```
Discovering from My Custom Source
Scanning: https://example.com/wiki
  Scope control: 45 in-scope URLs
```

### Why This Matters

Without scope control, crawling a site would eventually crawl:
- External news sites
- Social media links
- Advertiser domains
- Completely unrelated websites

With scope control, crawling `example.com` with domains `["example.com"]` will **only** discover:
- `https://example.com/*`
- `https://www.example.com/*`
- Any subdomain of `example.com`

All external links are silently filtered out and never added to the crawl queue.

## Data Directory

```
data/
├── sources/
│   └── <source>/
│       ├── discovered_urls.json       # Discovered URLs
│       └── discovered_urls.pb        # Protocol Buffers
├── documents/
│   ├── documents.json                # Exported JSON (debugging)
│   └── documents.pb                 # Protocol Buffers
├── chunks/
│   ├── chunks.json                   # Exported JSON (debugging)
│   └── chunks.pb                    # Protocol Buffers
└── embeddings/
    ├── embeddings.json              # Exported JSON (debugging)
    └── embeddings.pb                 # Protocol Buffers
```

| Format | Purpose |
|--------|---------|
| `*.json` | Human-readable for testing/debugging |
| `*.pb` | Binary for production pipeline |

## Progress Tracking

WebRAG provides real-time progress bars for long-running operations:

```
CRAWL PHASE
========================================
  Source: Archives of Nethys
  Discovered URLs: 15000
  Already Crawled: 5000
  To Crawl: 10000
  Max Concurrent: 8

[████████████████████░░░░░░] 80.0% | Crawled: 8000 | Failed: 50 | Pending: 2000
```

Embed phase also shows batch processing progress:

```
Processing with 4 concurrent batches...

[████████████████████░░░░░░] 80.0% | Completed: 8/10 | Failed: 0
```

## License

MIT License - see [LICENSE](LICENSE) for details.
