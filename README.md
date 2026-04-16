# AONCrawler

A multi-source web crawler for building RAG (Retrieval-Augmented Generation) datasets from any website.

## What It Does

AONCrawler discovers and crawls URLs from configured or custom sources, extracts content, generates embeddings, and enables semantic search. It supports:

- **Multiple sources**: Pre-configured sources or define your own
- **Scope control**: Only crawls URLs within allowed domains, preventing accidental crawling of unrelated sites
- **Parallel processing**: Concurrent crawling with configurable worker count (auto-detects CPU threads)
- **Protocol Buffers**: Fast binary serialization for production pipelines
- **RAG pipeline**: Extracts text, chunks content, generates embeddings, and enables semantic search

## Installation

```bash
# Clone the repository
git clone https://github.com/your-org/aoncrawler.git
cd aoncrawler

# Install dependencies
mix deps.get

# Compile Protocol Buffer schemas
mix compile
```

## Pipeline

AONCrawler uses a separate command for each stage of the pipeline:

```bash
mix discover    # 1. Find all URLs within scope
mix crawl       # 2. Crawl discovered URLs
mix index        # 3. Chunk documents
mix embed        # 4. Generate vector embeddings
mix compact      # 5. Export .pb files to JSON for debugging
mix query "..."  # 6. Semantic search
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

Crawls discovered URLs and extracts content.

```bash
mix crawl [options]
```

| Option | Description |
|--------|-------------|
| `--source <name>` | Source ID from config. Defaults to first source. |
| `--max <n>` | Maximum pages to crawl. Default: unlimited. |

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

#### Examples

```bash
# Index with defaults
mix index

# Custom chunk settings
mix index --chunk-size 500 --overlap 50
```

### `mix embed`

Generates vector embeddings for indexed chunks.

```bash
mix embed [options]
```

| Option | Description |
|--------|-------------|
| `--batch-size <n>` | Number of embeddings per batch. Default: 100. |

#### Examples

```bash
# Generate embeddings
mix embed

# Larger batches
mix embed --batch-size 256
```

### `mix query`

Performs semantic search and generates an LLM response.

```bash
mix query "<question>"
```

#### Examples

```bash
mix query "How does Shove work?"
```

## Adding Custom Sources

### Via Configuration

Add to `config/sources.exs`:

```elixir
config :aoncrawler, :sources,
  my_source: %{
    name: "My Custom Source",
    base_url: "https://docs.example.com",
    allowed_domains: ["example.com", "docs.example.com"],
    seed_urls: ["https://docs.example.com/"],
    rate_limit: 5,
    user_agent: "AONCrawler/1.0"
  }
```

### Via CLI (Runtime)

```bash
mix discover --base-url https://example.com --domains example.com
```

## Configuration

Edit `config/config.exs` or use environment variables:

```elixir
config :aoncrawler,
  max_concurrent: System.schedulers_online()

config :aoncrawler, AONCrawler.Indexer,
  embedding_model: "text-embedding-3-small",
  embedding_dimensions: 1536,
  batch_size: 100,
  max_concurrent_batches: System.schedulers_online()
```

Override via environment:

```bash
MAX_CONCURRENT=16 mix discover
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        mix discover                          │
│  - Parallel URL discovery (up to CPU threads)                │
│  - ETS table for deduplication                             │
│  - Scope filtering by allowed_domains                      │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                        mix crawl                            │
│  - Parallel crawling (up to CPU threads)                    │
│  - Content extraction with Floki                           │
│  - Rate limiting per host                                   │
│  - Skips already-crawled URLs                              │
│  - Filters invalid URLs (JavaScript, emails, etc.)          │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                        mix index                            │
│  - Reads documents.pb                                     │
│  - Chunks documents                                        │
│  - Writes chunks.json + chunks.pb                          │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                        mix embed                            │
│  - Parallel embedding generation                            │
│  - Batch API calls                                         │
│  - Writes embeddings.json + embeddings.pb                   │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                        mix compact                          │
│  - Exports .pb files to JSON for debugging                  │
│  - Reads: documents.pb, chunks.pb, embeddings.pb           │
│  - Writes: documents.json, chunks.json, embeddings.json      │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                        mix query                            │
│  - Semantic search via vector similarity                    │
│  - Context injection into LLM                              │
│  - Response generation                                      │
└─────────────────────────────────────────────────────────────┘
```

## Scope Control

AONCrawler enforces strict scope boundaries to prevent crawling unrelated sites or the entire internet.

### How It Works

When discovering URLs from a source, AONCrawler:

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
