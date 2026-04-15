# Aoncrawler

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `aoncrawler` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:aoncrawler, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/aoncrawler>.

Plan: Full Site Crawl with Parallel Processing

### Components to Modify

| File | Change | Effect |
|------|--------|--------|
| `lib/crawler/worker.ex:328-342` | Replace whitelist with exclude list | Follow all AoN links |
| `config/config.exs:16-17` | Increase rate & concurrent | Faster crawling |

---

### Configuration: Current vs. Proposed

| Setting | Current | Proposed | Speed Increase |
|--------|---------|----------|------------|
| `rate_limit` | 2 req/sec | 10 req/sec | 5x faster |
| `max_concurrent` | 5 workers | 20 workers | 4x faster |
| **Combined** | ~10 pages/sec | ~100 pages/sec | **10x faster** |

---

### Expected Performance

| Metric | Current Config | Proposed Config |
|--------|-------------|---------------|
| Total time | 8-10 hours | 1-2 hours |
| Pages/sec | ~10 | ~100 |
| Total pages | 30,000-50,000 | 30,000-50,000 |

---

### Code Changes Required

**1. `lib/crawler/worker.ex` (lines 328-342):**
```elixir
# BEFORE: whitelist - only specific page types
defp valid_aon_path?(url) do
  valid_paths = ["Actions.aspx", "Spells.aspx", ...]
  Enum.any?(valid_paths, &String.contains?(url, &1))
end

# AFTER: exclude list - all except non-rule pages
defp valid_aon_path?(url) do
  exclude_pages = ["Licenses.aspx", "Support.aspx", "ContactUs.aspx", "Contributors.aspx"]
  String.starts_with?(url, "https://2e.aonprd.com/") and
    not Enum.any?(exclude_pages, &String.contains?(url, &1))
end
```

**2. `config/config.exs` (optional - for speed):**
```elixir
config :aoncrawler, AONCrawler.Crawler,
  max_concurrent: 20,    # Was 5
  rate_limit: 10        # Was 2
```

---

### Execution Steps

```bash
# Start crawl (will take 1-2 hours)
mix crawl

# Wait for completion, then process:
mix load_aon
mix gen_embeddings --batch-size 32
mix query "How Shove Work"
```

---
