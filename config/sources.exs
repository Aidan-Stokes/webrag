import Config

config :aoncrawler, :sources,
  archives_of_nethys: %{
    name: "Archives of Nethys",
    base_url: "https://2e.aonprd.com",
    allowed_domains: ["2e.aonprd.com", "aonprd.com"],
    seed_urls: [
      "https://2e.aonprd.com/",
      "https://2e.aonprd.com/Actions.aspx",
      "https://2e.aonprd.com/Afflictions.aspx",
      "https://2e.aonprd.com/Ancestries.aspx",
      "https://2e.aonprd.com/Archetypes.aspx",
      "https://2e.aonprd.com/Backgrounds.aspx",
      "https://2e.aonprd.com/Classes.aspx",
      "https://2e.aonprd.com/Conditions.aspx",
      "https://2e.aonprd.com/Equipment.aspx",
      "https://2e.aonprd.com/Feats.aspx",
      "https://2e.aonprd.com/Hazards.aspx",
      "https://2e.aonprd.com/Monsters.aspx",
      "https://2e.aonprd.com/Rules.aspx",
      "https://2e.aonprd.com/Spells.aspx",
      "https://2e.aonprd.com/Traits.aspx",
      "https://2e.aonprd.com/Sources.aspx"
    ],
    rate_limit: 10,
    user_agent: "AONCrawler/1.0 (Pathfinder 2e Rules RAG)"
  },
  yahoo_finance: %{
    name: "Yahoo Finance News",
    base_url: "https://finance.yahoo.com",
    allowed_domains: ["finance.yahoo.com", "yahoo.com"],
    seed_urls: [
      "https://finance.yahoo.com/news/",
      "https://finance.yahoo.com/markets/"
    ],
    rate_limit: 5,
    user_agent: "AONCrawler/1.0 (Finance News RAG)"
  },
  national_archives: %{
    name: "U.S. National Archives",
    base_url: "https://www.archives.gov",
    allowed_domains: ["archives.gov", "nationalarchives.gov"],
    seed_urls: [
      "https://www.archives.gov/founding-docs",
      "https://www.archives.gov/constitution"
    ],
    rate_limit: 2,
    user_agent: "AONCrawler/1.0 (Historical Documents RAG)"
  }
