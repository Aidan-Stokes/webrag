defmodule WebRAG.Crawler.Source do
  @moduledoc """
  Represents a data source configuration for crawling.

  Each source defines:
  - Basic info (name, base URL)
  - Scope control (allowed domains)
  - Starting points (seed URLs)
  - Rate limiting configuration
  """

  @derive {Jason.Encoder, only: [:id, :name, :base_url, :allowed_domains, :seed_urls]}
  defstruct [
    :id,
    :name,
    :base_url,
    :allowed_domains,
    :seed_urls,
    :rate_limit,
    :user_agent
  ]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          base_url: String.t(),
          allowed_domains: [String.t()],
          seed_urls: [String.t()],
          rate_limit: non_neg_integer(),
          user_agent: String.t()
        }

  @doc """
  Returns all configured sources as a list of Source structs.
  """
  @spec list_sources() :: [t()]
  def list_sources do
    :webrag
    |> Application.get_env(:sources, [])
    |> Enum.map(fn {id, config} ->
      struct(__MODULE__, Map.put(config, :id, id))
    end)
  end

  @doc """
  Returns a source by its ID (atom key).
  """
  @spec get_source(atom()) :: t() | nil
  def get_source(id) when is_atom(id) do
    sources = Application.get_env(:webrag, :sources, [])

    case List.keyfind(sources, id, 0) do
      {^id, config} ->
        struct(__MODULE__, Map.put(config, :id, id))

      nil ->
        nil
    end
  end

  @doc """
  Returns all source IDs.
  """
  @spec source_ids() :: [atom()]
  def source_ids do
    :webrag
    |> Application.get_env(:sources, [])
    |> Keyword.keys()
  end

  @doc """
  Returns all allowed domains from a list of sources.
  """
  @spec all_domains([t()]) :: [String.t()]
  def all_domains(sources) do
    sources
    |> Enum.flat_map(& &1.allowed_domains)
    |> Enum.uniq()
  end

  @doc """
  Checks if a URL is within the scope of this source.
  """
  @spec within_scope?(String.t(), t()) :: boolean()
  def within_scope?(url, %__MODULE__{allowed_domains: domains}) do
    case URI.parse(url) do
      %{host: nil} -> false
      %{host: host} -> Enum.any?(domains, &domain_matches?(host, &1))
      _ -> false
    end
  end

  defp domain_matches?(host, domain) do
    host == domain or String.ends_with?(host, ".#{domain}")
  end

  @doc """
  Validates if a URL matches the source's URL patterns.
  Returns true if the URL is valid for this source.
  """
  @spec valid_url?(String.t(), t()) :: boolean()
  def valid_url?(url, %__MODULE__{} = source) do
    normalized = normalize_url(url)
    within_scope?(normalized, source) and valid_uri?(normalized)
  end

  @doc """
  Normalizes a URL to canonical form:
  - Converts http:// to https://
  - Converts aonprd.com to 2e.aonprd.com
  - Removes trailing slashes
  """
  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) do
    url
    |> String.replace(~r/^http:\/\/aonprd\.com/i, "https://2e.aonprd.com")
    |> String.replace(~r/^https?:\/\/aonprd\.com/i, "https://2e.aonprd.com")
    |> String.replace(~r/^http:\/\//i, "https://")
    |> String.trim_trailing("/")
  end

  @doc """
  Pages that consistently return server errors (500, 404) and should be skipped.
  These are listing/index pages that don't have content.
  """
  @spec blocklist_pages() :: [String.t()]
  def blocklist_pages do
    [
      # Search pages
      "Search.aspx",
      "SearchOld.aspx",
      # Display pages (need IDs)
      "SourceDisplay.aspx",
      "ArchetypeDisplay.aspx",
      "SpellDisplay.aspx",
      "ClassDisplay.aspx",
      "RacesDisplay.aspx",
      "MonsterDisplay.aspx",
      "MythicMonsterDisplay.aspx",
      "FeatDisplay.aspx",
      "TraitDisplay.aspx",
      "DeityDisplay.aspx",
      "DomainDisplay.aspx",
      "BloodlineDisplay.aspx",
      "MysteryDisplay.aspx",
      "WildbloodedDisplay.aspx",
      "SpellbookDisplay.aspx",
      "PoisonDisplay.aspx",
      "ShadowPiercingsDisplay.aspx",
      "MagicArmorDisplay.aspx",
      "MagicWeaponsDisplay.aspx",
      "MagicWondrousDisplay.aspx",
      "MagicRingsDisplay.aspx",
      "MagicStavesDisplay.aspx",
      "MagicPotionsDisplay.aspx",
      "MagicRodsDisplay.aspx",
      "MagicArtifactsDisplay.aspx",
      "MagicAltarsDisplay.aspx",
      "MagicPlantsDisplay.aspx",
      "MagicIntelligentDisplay.aspx",
      "MagicThronesDisplay.aspx",
      "MagicFavorsDisplay.aspx",
      "MagicCursedDisplay.aspx",
      "MagicFleshcraftingDisplay.aspx",
      "MagicGenieSealsDisplay.aspx",
      "MagicDemonicImplantsDisplay.aspx",
      "MagicThassilonianRunesDisplay.aspx",
      "MagicTattooDisplay.aspx",
      "MagicScalingDisplay.aspx",
      "MagicSetsDisplay.aspx",
      "MagicDevilTalismansDisplay.aspx",
      "MagicPlantsDisplay.aspx",
      "EquipmentArmorDisplay.aspx",
      "EquipmentWeaponsDisplay.aspx",
      "EquipmentMiscDisplay.aspx",
      "EquipmentTechArmorDisplay.aspx",
      "EquipmentTechWeaponsDisplay.aspx",
      "EquipmentTechPharmaceuticalsDisplay.aspx",
      "EquipmentTechArtifactsDisplay.aspx",
      "KineticistTalentsDisplay.aspx",
      # Index pages (no content without ID)
      "Spells.aspx",
      "Feats.aspx",
      "Actions.aspx",
      "Classes.aspx",
      "Races.aspx",
      "Monsters.aspx",
      "Traits.aspx",
      "Rules.aspx",
      "Equipment.aspx",
      "MagicItems.aspx",
      "SpellsCustom.aspx",
      "MagicArmor.aspx",
      "MagicWeapons.aspx",
      "MagicWondrous.aspx",
      "MagicRings.aspx",
      "MagicStaves.aspx",
      "MagicPotions.aspx",
      "MagicRods.aspx",
      "MagicArtifacts.aspx",
      "MagicAltars.aspx",
      "MagicPlants.aspx",
      "MagicThrones.aspx",
      "MagicFavors.aspx",
      "MagicCursed.aspx",
      "MagicFleshcrafting.aspx",
      "MagicGenieSeals.aspx",
      "MagicDemonicImplants.aspx",
      "MagicThassilonianRunes.aspx",
      "MagicTattoos.aspx",
      "MagicScaling.aspx",
      "MagicSets.aspx",
      "MagicDevilTalismans.aspx",
      "MagicIntelligent.aspx",
      "MagicOther.aspx",
      "SpecialMaterials.aspx",
      "ConstructMods.aspx",
      "Haunts.aspx",
      "Traps.aspx",
      "Madnesses.aspx",
      "Corruptions.aspx",
      "Drugs.aspx",
      "Poisons.aspx",
      "InfusedPoisons.aspx",
      "Necrotoxins.aspx",
      "AlchemicalReagents.aspx",
      "DeityDetails.aspx",
      "DeitiesByGroup.aspx",
      "SorcererBloodlines.aspx",
      "OracleCurses.aspx",
      "OracleMysteries.aspx",
      "ClericDomains.aspx",
      "ClericVariantChanneling.aspx",
      "DruidCompanions.aspx",
      "InvestigatorTalents.aspx",
      "RogueTalents.aspx",
      "BarbarianRagePowers.aspx",
      "MonkUCStyleStrikes.aspx",
      "MonkUCKiPowers.aspx",
      "GunslingerDeeds.aspx",
      "GunslingerDares.aspx",
      "PathAbilities.aspx",
      "KineticistTalents.aspx",
      "KineticistElements.aspx",
      "AlchemistDiscoveries.aspx",
      "BloodlineMutations.aspx",
      "Wildblooded.aspx",
      "Mythic.aspx",
      "MythicPaths.aspx",
      "MythicMonsters.aspx",
      "PrestigeClasses.aspx",
      "PrestigeClassesDisplay.aspx",
      "ElementalAugmentations.aspx",
      "FungalGrafts.aspx",
      "Necrografts.aspx",
      "ShadowPiercings.aspx",
      "RandomBackground.aspx",
      "RandomItemGenerator.aspx",
      "Annointings.aspx",
      "Default.aspx",
      "UMR.aspx",
      "ClassSamples.aspx",
      "EarnIncomeCalc.aspx",
      "FAQ.aspx",
      "Tools.aspx",
      "Projects.aspx",
      "CombatStamina.aspx",
      "MasterSummonList.aspx",
      "SpellDefinitions.aspx",
      "UMR.aspx",
      "RogueTalents.aspx",
      "MonsterTypes.aspx",
      "MonsterSubtypes.aspx",
      "EquipmentArmor.aspx",
      "EquipmentWeapons.aspx",
      "EquipmentMisc.aspx",
      "EquipmentTech.aspx",
      "EquipmentTechMisc.aspx",
      "EquipmentTechWeapons.aspx",
      "EquipmentTechArmor.aspx",
      "EquipmentTechPharamaceuticals.aspx",
      "EquipmentTechPharmaceuticals.aspx",
      "EquipmentTechCybertech.aspx",
      "EquipmentTechArtifacts.aspx",
      "Spellbooks.aspx",
      "OccultRituals.aspx",
      "FAQs.aspx",
      "MagicJujuFetishes.aspx"
    ]
  end

  @doc """
  Checks if a URL points to a blocklisted page.
  """
  @spec blocklisted?(String.t()) :: boolean()
  def blocklisted?(url) do
    Enum.any?(blocklist_pages(), &String.contains?(url, &1))
  end

  @doc """
  Checks if a URL has invalid characters (like backslashes).
  """
  @spec has_invalid_chars?(String.t()) :: boolean()
  def has_invalid_chars?(url) do
    String.contains?(url, "\\")
  end

  defp valid_uri?(url) do
    case URI.parse(url) do
      %{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        true

      _ ->
        false
    end
  end

  @doc """
  Resolves a href relative to a base URL.
  """
  @spec resolve_url(String.t(), String.t()) :: String.t() | nil
  def resolve_url(href, base_url) do
    case URI.parse(href) do
      %{scheme: scheme} when scheme in ["http", "https"] ->
        href

      %{host: nil, path: path} ->
        case URI.parse(base_url) do
          %{scheme: scheme, host: host, port: port} ->
            base = %URI{scheme: scheme, host: host, port: port, path: "/"}
            URI.merge(base, path) |> URI.to_string() |> String.trim_trailing("/")

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns the data directory path for a source.
  """
  @spec data_dir(t()) :: String.t()
  def data_dir(%__MODULE__{id: id}) do
    Path.expand("../data/sources/#{id}", __DIR__)
  end

  @doc """
  Ensures the data directory for a source exists.
  """
  @spec ensure_data_dir(t()) :: :ok
  def ensure_data_dir(%__MODULE__{} = source) do
    dir = data_dir(source)
    File.mkdir_p!(dir)
    :ok
  end

  @doc """
  Creates a source from CLI arguments.

  ## Options

    - `:id` - Source ID (atom)
    - `:name` - Human-readable name
    - `:base_url` - Primary base URL
    - `:allowed_domains` - List of allowed domains
    - `:seed_urls` - List of seed URLs (defaults to base_url)
    - `:rate_limit` - Requests per second
    - `:user_agent` - User-Agent string

  ## Examples

      Source.from_cli(
        base_url: "https://example.com",
        allowed_domains: ["example.com", "www.example.com"]
      )
  """
  @spec from_cli(keyword()) :: t()
  def from_cli(opts) do
    id = Keyword.get(opts, :id, :custom)
    name = Keyword.get(opts, :name, "Custom Source")
    base_url = Keyword.get(opts, :base_url)
    allowed_domains = Keyword.get(opts, :allowed_domains, [])
    seed_urls = Keyword.get(opts, :seed_urls, [base_url])
    rate_limit = Keyword.get(opts, :rate_limit, 5)
    user_agent = Keyword.get(opts, :user_agent, "WebRAG/1.0")

    unless base_url do
      raise ArgumentError, "base_url is required"
    end

    unless Enum.any?(allowed_domains) do
      raise ArgumentError, "allowed_domains is required"
    end

    %__MODULE__{
      id: id,
      name: name,
      base_url: base_url,
      allowed_domains: allowed_domains,
      seed_urls: seed_urls,
      rate_limit: rate_limit,
      user_agent: user_agent
    }
  end

  @doc """
  Parses a comma-separated string of domains into a list.
  """
  @spec parse_domains(String.t()) :: [String.t()]
  def parse_domains(domains_string) do
    domains_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Filters a list of URLs, returning only those within scope.
  Also returns count of filtered URLs.

  ## Examples

      iex> source = Source.from_cli(base_url: "https://example.com", allowed_domains: ["example.com"])
      iex> {in_scope, filtered} = Source.filter_by_scope(["https://example.com", "https://other.com"], source)
      iex> in_scope
      ["https://example.com"]
      iex> filtered
      1
  """
  @spec filter_by_scope([String.t()], t()) :: {[String.t()], non_neg_integer()}
  def filter_by_scope(urls, source) do
    {in_scope, out_of_scope} =
      Enum.split_with(urls, &within_scope?(&1, source))

    {in_scope, length(out_of_scope)}
  end

  @doc """
  Returns a list of URLs that would be filtered out (outside scope).
  Useful for debugging and auditing scope boundaries.
  """
  @spec out_of_scope_urls([String.t()], t()) :: [String.t()]
  def out_of_scope_urls(urls, source) do
    Enum.reject(urls, &within_scope?(&1, source))
  end
end
