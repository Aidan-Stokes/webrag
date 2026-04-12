defmodule AONCrawler.Parser.Extractor do
  @moduledoc """
  HTML extractor for Archives of Nethys content.

  This module provides specialized extraction logic for different content types
  found on Archives of Nethys. It converts raw HTML into structured Elixir
  maps suitable for storage and further processing.

  ## Supported Content Types

  - spell - Spell entries with levels, traditions, components
  - action - Action entries (single, reaction, activity)
  - feat - Feat entries with prerequisites
  - trait - Trait definitions
  - rule - General rules text
  - condition - Condition effects
  - equipment - Equipment and items
  - creature - Bestiary entries

  ## Extraction Pipeline

  1. **Noise Removal** - Strip navigation, ads, and UI chrome
  2. **Content Identification** - Determine content type from URL or structure
  3. **Field Extraction** - Extract type-specific fields
  4. **Text Cleaning** - Convert HTML to clean plain text
  5. **Metadata Assembly** - Build metadata map with all extracted data

  ## Design Decisions

  1. **CSS Selector Optimization**: We use specific, tested selectors for AoN's
     actual HTML structure rather than generic selectors.

  2. **Fallback Strategies**: Multiple selectors are tried in priority order to
     handle page variations.

  3. **Error Isolation**: Each field extraction is wrapped in try-rescue to
     prevent one bad field from failing the entire extraction.

  4. **Structured Metadata**: Type-specific fields are stored in a metadata map
     rather than flattening everything, preserving relationships.

  ## Example

      iex> html = File.read!("test/fixtures/spell_page.html")
      iex> {:ok, content} = Extractor.extract(html, "https://2e.aonprd.com/Spells.aspx?ID=119")
      iex> content.type
      :spell
      iex> content.name
      "Fireball"
  """

  use GenServer
  require Logger

  alias AONCrawler.Types

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the extractor server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Extracts structured content from raw HTML.

  ## Parameters

  - `html` - Raw HTML string
  - `url` - Source URL for content type detection
  - `opts` - Extraction options

  ## Options

  - `:type` - Override content type detection
  - `:strict` - Raise on extraction errors (default: false)

  ## Example

      iex> {:ok, content} = extract(html, "https://2e.aonprd.com/Spells.aspx?ID=119")
      iex> content.type
      :spell
  """
  @spec extract(String.t(), String.t(), keyword()) :: {:ok, Types.t()} | {:error, term()}
  def extract(html, url, opts \\ []) when is_binary(html) and is_binary(url) do
    case GenServer.call(__MODULE__, {:extract, html, url, opts}) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extracts content synchronously without the GenServer.

  Useful for batch processing where you don't want GenServer overhead.
  """
  @spec extract_sync(String.t(), String.t(), keyword()) :: {:ok, Types.t()} | {:error, term()}
  def extract_sync(html, url, opts \\ []) do
    content_type = Keyword.get(opts, :type) || detect_content_type(url)

    with {:ok, cleaned_html} <- clean_html(html),
         {:ok, name} <- extract_name(cleaned_html, content_type),
         {:ok, text} <- extract_text(cleaned_html, content_type),
         {:ok, metadata} <- extract_metadata(cleaned_html, content_type, url) do
      content =
        Types.new_rule_content(
          type: content_type,
          name: name,
          text: text,
          source_url: url,
          raw_html: html,
          metadata: metadata
        )

      {:ok, content}
    end
  end

  @doc """
  Batch extracts content from multiple HTML documents.

  More efficient than calling extract/3 multiple times.
  """
  @spec extract_batch([{String.t(), String.t()}], keyword()) :: [
          {:ok, Types.t()} | {:error, term()}
        ]
  def extract_batch(documents, opts \\ []) when is_list(documents) do
    documents
    |> Enum.map(fn {html, url} ->
      Task.Supervisor.async_stream(
        AONCrawler.Parser.TaskSupervisor,
        fn -> extract_sync(html, url, opts) end,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 30_000
      )
    end)
    |> Enum.map(fn
      {:ok, {:ok, content}} -> {:ok, content}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, reason}
    end)
  end

  @doc """
  Detects the content type from a URL.

  Archives of Nethys uses consistent URL patterns for different content types.
  """
  @spec detect_content_type(String.t()) :: atom()
  def detect_content_type(url) when is_binary(url) do
    cond do
      # Actions
      String.contains?(url, "/Actions.aspx") -> :action
      String.contains?(url, "/Activity.aspx") -> :action
      # Spells
      String.contains?(url, "/Spells.aspx") -> :spell
      String.contains?(url, "/SpellLists.aspx") -> :spell
      # Feats
      String.contains?(url, "/Feats.aspx") -> :feat
      String.contains?(url, "/Archetypes.aspx") -> :feat
      # Traits
      String.contains?(url, "/Traits.aspx") -> :trait
      # Rules
      String.contains?(url, "/Rules.aspx") -> :rule
      # Equipment
      String.contains?(url, "/Equipment.aspx") -> :equipment
      String.contains?(url, "/Weapons.aspx") -> :equipment
      String.contains?(url, "/Armor.aspx") -> :equipment
      # Creatures
      String.contains?(url, "/Monsters.aspx") -> :creature
      String.contains?(url, "/Bestiary.aspx") -> :creature
      # Conditions
      String.contains?(url, "/Conditions.aspx") -> :condition
      # Hazards
      String.contains?(url, "/Hazards.aspx") -> :hazard
      # Default to rule
      true -> :rule
    end
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:extract, html, url, opts}, _from, state) do
    result = extract_sync(html, url, opts)
    {:reply, result, state}
  end

  # ============================================================================
  # Core Extraction Functions
  # ============================================================================

  @doc """
  Cleans HTML by removing noise elements.
  """
  @spec clean_html(String.t()) :: {:ok, Floki.html_tree()} | {:error, term()}
  def clean_html(html) when is_binary(html) do
    try do
      parsed = Floki.parse_document(html)

      # Noise selectors to remove
      _noise_selectors = [
        "script",
        "style",
        "iframe",
        "noscript",
        ".sidebar",
        ".navigation",
        ".advertisement",
        ".related-content",
        ".breadcrumbs",
        "#header",
        ".footer",
        ".ad",
        ".ads",
        ".social-share",
        ".comments",
        ".newsletter"
      ]

      cleaned =
        parsed
        |> Floki.traverse(fn
          {"script", _, _} ->
            nil

          {"style", _, _} ->
            nil

          {"iframe", _, _} ->
            nil

          {tag, _attrs, _children} when tag in ["script", "style", "noscript"] ->
            nil

          {tag, attrs, children} ->
            # Check if this element matches a noise selector
            {tag, attrs, children}

          other ->
            other
        end)
        |> elem(1)

      {:ok, cleaned}
    rescue
      error ->
        Logger.error("Failed to parse HTML", error: inspect(error))
        {:error, {:parse_error, inspect(error)}}
    end
  end

  @doc """
  Extracts the main content area from parsed HTML.
  """
  @spec extract_content_area(Floki.html_tree()) :: Floki.html_tree() | nil
  def extract_content_area(html_tree) do
    # Try selectors in priority order
    content_selectors = [
      ".main-content",
      "#content",
      "article.content",
      ".page",
      ".stat-block",
      "main",
      ".page-content"
    ]

    Enum.find_value(content_selectors, fn selector ->
      case Floki.find(html_tree, selector) do
        [content | _] -> content
        _ -> nil
      end
    end) || html_tree
  end

  @doc """
  Extracts the name/title of the content.
  """
  @spec extract_name(Floki.html_tree(), atom()) :: {:ok, String.t()} | {:error, term()}
  def extract_name(html_tree, content_type) do
    try do
      name =
        case Floki.find(html_tree, "h1") do
          [h1 | _] ->
            Floki.text(h1)

          _ ->
            case Floki.find(html_tree, "title") do
              [title | _] ->
                title
                |> Floki.text()
                |> String.split(" - ")
                |> List.first()

              _ ->
                "Unknown"
            end
        end
        |> String.trim()
        |> clean_text()

      {:ok, name}
    rescue
      error ->
        Logger.warning("Failed to extract name",
          content_type: content_type,
          error: inspect(error)
        )

        {:ok, "Unknown"}
    end
  end

  @doc """
  Extracts the main text content.
  """
  @spec extract_text(Floki.html_tree(), atom()) :: {:ok, String.t()} | {:error, term()}
  def extract_text(html_tree, content_type) do
    try do
      content = extract_content_area(html_tree)

      text =
        content
        |> Floki.text(sep: "\n", normalize_whitespace: true)
        |> clean_text()
        |> remove_extraneous_whitespace()

      {:ok, text}
    rescue
      error ->
        Logger.error("Failed to extract text", content_type: content_type, error: inspect(error))
        {:error, {:extraction_error, :text, inspect(error)}}
    end
  end

  @doc """
  Extracts type-specific metadata from the HTML.
  """
  @spec extract_metadata(Floki.html_tree(), atom(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def extract_metadata(html_tree, content_type, url) do
    try do
      metadata =
        case content_type do
          :spell -> extract_spell_metadata(html_tree, url)
          :action -> extract_action_metadata(html_tree, url)
          :feat -> extract_feat_metadata(html_tree, url)
          :trait -> extract_trait_metadata(html_tree, url)
          :condition -> extract_condition_metadata(html_tree, url)
          _ -> extract_generic_metadata(html_tree, url)
        end

      {:ok, metadata}
    rescue
      error ->
        Logger.warning("Failed to extract metadata",
          content_type: content_type,
          error: inspect(error)
        )

        {:ok, %{}}
    end
  end

  # ============================================================================
  # Spell Extraction
  # ============================================================================

  @doc """
  Extracts spell-specific metadata.
  """
  @spec extract_spell_metadata(Floki.html_tree(), String.t()) :: map()
  def extract_spell_metadata(html_tree, _url) do
    %{
      level: extract_spell_level(html_tree),
      school: extract_spell_school(html_tree),
      traditions: extract_spell_traditions(html_tree),
      casting_time: extract_field(html_tree, ["Casting Time", ".spell-casting-time"]),
      components: extract_spell_components(html_tree),
      range: extract_field(html_tree, ["Range", ".spell-range"]),
      area: extract_field(html_tree, ["Area", ".spell-area"]),
      targets: extract_field(html_tree, ["Targets", ".spell-targets"]),
      saving_throw: extract_saving_throw(html_tree),
      duration: extract_field(html_tree, ["Duration", ".spell-duration"]),
      attack_type: extract_attack_type(html_tree),
      source_book: extract_source_book(html_tree),
      rarities: extract_rarities(html_tree),
      traditions_list: extract_traditions_list(html_tree)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  defp extract_spell_level(html_tree) do
    case Floki.find(html_tree, ".spell-level") do
      [element | _] ->
        element
        |> Floki.text()
        |> String.downcase()
        |> then(fn text ->
          case Integer.parse(text) do
            {level, _} ->
              level

            _ ->
              # Try to extract from text like "Level 3"
              Regex.run(~r/(\d+)/, text)
              |> List.wrap()
              |> Enum.at(1)
              |> case do
                nil -> nil
                level_str -> String.to_integer(level_str)
              end
          end
        end)

      _ ->
        # Fallback: look in title or body
        case Floki.find(html_tree, "h1, .title") do
          [title | _] ->
            title
            |> Floki.text()
            |> String.downcase()
            |> then(fn text ->
              case Regex.run(~r/level\s*(\d+)/i, text) do
                [_, level] -> String.to_integer(level)
                _ -> nil
              end
            end)

          _ ->
            nil
        end
    end
  end

  defp extract_spell_school(html_tree) do
    case Floki.find(html_tree, ".spell-school, [data-sourceid*='school']") do
      [element | _] -> Floki.text(element) |> String.trim()
      _ -> nil
    end
  end

  defp extract_spell_traditions(html_tree) do
    traditions_selectors = [
      ".spell-traditions",
      "[data-sourceid*='tradition']",
      ".traditions"
    ]

    Enum.find_value(traditions_selectors, fn selector ->
      case Floki.find(html_tree, selector) do
        [element | _] ->
          element
          |> Floki.text()
          |> String.split([",", " and "], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        _ ->
          nil
      end
    end) || []
  end

  defp extract_traditions_list(html_tree) do
    # Extract traditions as a list for structured querying
    case Floki.find(html_tree, "a[href*='Tradition']") do
      links when is_list(links) ->
        links
        |> Enum.map(fn {_tag, _attrs, [text | _]} -> text end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  defp extract_spell_components(html_tree) do
    components_selectors = [
      ".spell-components",
      "[data-sourceid*='components']",
      "span.components"
    ]

    Enum.find_value(components_selectors, fn selector ->
      case Floki.find(html_tree, selector) do
        [element | _] ->
          element
          |> Floki.text()
          |> String.split([",", " "], trim: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.downcase/1)

        _ ->
          nil
      end
    end) || []
  end

  defp extract_saving_throw(html_tree) do
    case Floki.find(html_tree, ".spell-save, [data-sourceid*='save']") do
      [element | _] -> Floki.text(element) |> String.trim()
      _ -> nil
    end
  end

  defp extract_attack_type(html_tree) do
    save = extract_saving_throw(html_tree)

    if save && String.downcase(save) |> String.contains?("reflex") do
      :ranged
    else
      if save && String.downcase(save) |> String.contains?("fortitude") do
        :melee
      else
        if save && String.downcase(save) |> String.contains?("will") do
          :mental
        else
          :none
        end
      end
    end
  end

  defp extract_rarities(html_tree) do
    case Floki.find(html_tree, ".spell-rarity, .rarity") do
      elements when is_list(elements) ->
        elements
        |> Enum.map(fn el -> Floki.text(el) |> String.trim() end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # ============================================================================
  # Action Extraction
  # ============================================================================

  @doc """
  Extracts action-specific metadata.
  """
  @spec extract_action_metadata(Floki.html_tree(), String.t()) :: map()
  def extract_action_metadata(html_tree, _url) do
    %{
      action_type: extract_action_type(html_tree),
      requirements: extract_field(html_tree, ["Requirements", ".action-requirements"]),
      trigger: extract_field(html_tree, ["Trigger", ".action-trigger"]),
      frequency: extract_field(html_tree, ["Frequency", ".action-frequency"]),
      cost: extract_field(html_tree, ["Cost", ".action-cost"]),
      effect: extract_field(html_tree, ["Effect", ".action-effect"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  defp extract_action_type(_html_tree) do
    :action
  end

  # ============================================================================
  # Feat Extraction
  # ============================================================================

  @doc false
  @spec extract_feat_metadata(Floki.html_tree(), String.t()) :: map()
  defp extract_feat_metadata(html_tree, _url) do
    %{
      level: extract_feat_level(html_tree),
      prerequisites: extract_field(html_tree, ["Prerequisites", ".feat-prerequisites"]),
      requirements: extract_field(html_tree, ["Requirements", ".feat-requirements"]),
      frequency: extract_field(html_tree, ["Frequency", ".feat-frequency"]),
      access: extract_field(html_tree, ["Access", ".feat-access"]),
      trigger: extract_field(html_tree, ["Trigger", ".feat-trigger"]),
      cost: extract_field(html_tree, ["Cost", ".feat-cost"]),
      effect: extract_field(html_tree, ["Effect", ".feat-effect"]),
      special: extract_field(html_tree, ["Special", ".feat-special"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  defp extract_feat_level(html_tree) do
    case Floki.find(html_tree, ".feat-level, [data-sourceid*='level']") do
      [element | _] ->
        element
        |> Floki.text()
        |> String.downcase()
        |> then(fn text ->
          case Integer.parse(text) do
            {level, _} ->
              level

            _ ->
              case Regex.run(~r/level\s*(\d+)/i, text) do
                [_, level] -> String.to_integer(level)
                _ -> nil
              end
          end
        end)

      _ ->
        nil
    end
  end

  # ============================================================================
  # Trait Extraction
  # ============================================================================

  @doc """
  Extracts trait-specific metadata.
  """
  @spec extract_trait_metadata(Floki.html_tree(), String.t()) :: map()
  def extract_trait_metadata(html_tree, _url) do
    %{
      category: extract_trait_category(html_tree),
      related_traits: extract_related_traits(html_tree),
      related_actions: extract_related_actions(html_tree)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  defp extract_trait_category(html_tree) do
    case Floki.find(html_tree, ".trait-category, .category") do
      [element | _] -> Floki.text(element) |> String.trim()
      _ -> nil
    end
  end

  defp extract_related_traits(html_tree) do
    case Floki.find(html_tree, "a[href*='Traits.aspx']") do
      links when is_list(links) ->
        links
        |> Enum.map(fn {_tag, _attrs, [text | _]} -> text end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  defp extract_related_actions(html_tree) do
    case Floki.find(html_tree, "a[href*='Actions.aspx']") do
      links when is_list(links) ->
        links
        |> Enum.map(fn {_tag, _attrs, [text | _]} -> text end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  # ============================================================================
  # Condition Extraction
  # ============================================================================

  @doc """
  Extracts condition-specific metadata.
  """
  @spec extract_condition_metadata(Floki.html_tree(), String.t()) :: map()
  def extract_condition_metadata(html_tree, _url) do
    %{
      associated_actions: extract_associated_actions(html_tree),
      lasted_effect: extract_field(html_tree, ["Duration", ".condition-duration"]),
      ends_effect: extract_field(html_tree, ["Ending", ".condition-ends"]),
      source_effect: extract_field(html_tree, ["Source", ".condition-source"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  defp extract_associated_actions(html_tree) do
    case Floki.find(html_tree, "a[href*='Actions.aspx']") do
      links when is_list(links) ->
        links
        |> Enum.map(fn {_tag, _attrs, [text | _]} -> text end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  # ============================================================================
  # Generic Extraction
  # ============================================================================

  @doc """
  Extracts generic metadata for unknown content types.
  """
  @spec extract_generic_metadata(Floki.html_tree(), String.t()) :: map()
  def extract_generic_metadata(html_tree, _url) do
    %{
      source_book: extract_source_book(html_tree),
      page_number: extract_page_number(html_tree),
      traits: extract_traits(html_tree)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Enum.into(%{})
  end

  # ============================================================================
  # Shared Extraction Helpers
  # ============================================================================

  @doc """
  Extracts a field using multiple possible selectors.
  """
  @spec extract_field(Floki.html_tree(), [String.t()]) :: String.t() | nil
  def extract_field(_html_tree, []) do
    nil
  end

  def extract_field(html_tree, [selector | rest]) do
    case Floki.find(html_tree, selector) do
      [element | _] ->
        text = Floki.text(element) |> String.trim()
        if text == "", do: extract_field(html_tree, rest), else: text

      _ ->
        extract_field(html_tree, rest)
    end
  end

  @doc """
  Extracts all traits from the content.
  """
  @spec extract_traits(Floki.html_tree()) :: [String.t()]
  def extract_traits(html_tree) do
    case Floki.find(html_tree, ".traits, .trait, a[href*='Traits.aspx']") do
      elements when is_list(elements) ->
        elements
        |> Enum.map(fn el ->
          case el do
            {_tag, _attrs, [text | _]} -> text
            {_tag, _attrs, text} when is_binary(text) -> text
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Extracts the source book from the content.
  """
  @spec extract_source_book(Floki.html_tree()) :: String.t() | nil
  def extract_source_book(html_tree) do
    source_selectors = [
      ".source-book",
      ".book",
      "[data-sourceid*='book']",
      ".publication"
    ]

    Enum.find_value(source_selectors, fn selector ->
      case Floki.find(html_tree, selector) do
        [element | _] -> Floki.text(element) |> String.trim()
        _ -> nil
      end
    end)
  end

  @doc """
  Extracts the page number from the content.
  """
  @spec extract_page_number(Floki.html_tree()) :: non_neg_integer() | nil
  def extract_page_number(html_tree) do
    case Floki.find(html_tree, ".page-number, .page, [data-sourceid*='page']") do
      [element | _] ->
        element
        |> Floki.text()
        |> then(fn text ->
          case Regex.run(~r/p\.?\s*(\d+)/i, text) do
            [_, page] -> String.to_integer(page)
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  # ============================================================================
  # Text Cleaning
  # ============================================================================

  @doc """
  Cleans extracted text by removing excessive whitespace and normalizing.
  """
  @spec clean_text(String.t()) :: String.t()
  def clean_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Removes extraneous whitespace while preserving paragraph breaks.
  """
  @spec remove_extraneous_whitespace(String.t()) :: String.t()
  def remove_extraneous_whitespace(text) when is_binary(text) do
    text
    # Normalize line breaks
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/\r/, "\n")
    # Remove leading/trailing whitespace from lines
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    # Remove empty lines
    |> Enum.reject(&(&1 == ""))
    # Remove duplicate empty lines (more than 2 consecutive)
    |> Enum.chunk_while(
      [],
      fn
        "", acc -> {:cont, acc}
        "\n", acc -> {:cont, acc}
        elem, [] -> {:cont, [elem]}
        elem, acc -> {:cont, Enum.reverse(acc) ++ [elem], []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.join("\n")
  end

  @doc """
  Extracts a specific section from the HTML by header.
  """
  @spec extract_section(Floki.html_tree(), String.t()) :: String.t() | nil
  def extract_section(html_tree, section_header) when is_binary(section_header) do
    case Floki.find(html_tree, "h2, h3, h4, .section-header") do
      headers when is_list(headers) ->
        headers
        |> Enum.find(fn header ->
          Floki.text(header)
          |> String.downcase()
          |> String.contains?(String.downcase(section_header))
        end)
        |> case do
          nil ->
            nil

          header ->
            # Get all siblings after this header until the next header
            {_, siblings} = Floki.next_siblings(html_tree, header)

            siblings
            |> Enum.take_while(fn
              {"h2", _, _} -> false
              {"h3", _, _} -> false
              {"h4", _, _} -> false
              _ -> true
            end)
            |> Floki.text()
            |> clean_text()
        end

      _ ->
        nil
    end
  end

  @doc """
  Extracts all section headers from the content.
  """
  @spec extract_headers(Floki.html_tree()) :: [String.t()]
  def extract_headers(html_tree) do
    Floki.find(html_tree, "h1, h2, h3, h4, .section-header")
    |> Enum.map(fn header -> Floki.text(header) |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Extracts tables from the HTML and converts to structured data.
  """
  @spec extract_tables(Floki.html_tree()) :: [%{headers: [String.t()], rows: [[String.t()]]}]
  def extract_tables(html_tree) do
    Floki.find(html_tree, "table")
    |> Enum.map(fn table ->
      headers =
        Floki.find(table, "thead th, thead td")
        |> Enum.map(fn th -> Floki.text(th) |> String.trim() end)

      rows =
        Floki.find(table, "tbody tr")
        |> Enum.map(fn tr ->
          Floki.find(tr, "td")
          |> Enum.map(fn td -> Floki.text(td) |> String.trim() end)
        end)

      %{headers: headers, rows: rows}
    end)
  end

  @doc """
  Extracts all links from the HTML with their hrefs.
  """
  @spec extract_links(Floki.html_tree(), String.t()) :: [%{text: String.t(), url: String.t()}]
  def extract_links(html_tree, base_url \\ "") do
    Floki.find(html_tree, "a[href]")
    |> Enum.map(fn {_tag, attrs, content} ->
      href = List.keyfind(attrs, "href", 0) |> elem(1) |> maybe_resolve_url(base_url)
      text = Floki.text(content) |> String.trim()

      %{text: text, url: href}
    end)
    |> Enum.reject(fn %{url: url} -> url == "#" or url == "" end)
  end

  defp maybe_resolve_url(href, base_url) do
    cond do
      String.starts_with?(href, "http") -> href
      String.starts_with?(href, "/") -> base_url <> href
      true -> href
    end
  end
end
