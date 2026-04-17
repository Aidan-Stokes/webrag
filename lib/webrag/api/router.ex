defmodule WebRAG.API.Router do
  @moduledoc """
  Router for the WebRAG API.

  Provides HTTP endpoints for:
  - POST /query - Ask a rules question
  - GET /health - Health check
  - GET /stats - System statistics
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", WebRAG.API do
    pipe_through(:api)

    post("/query", Controller, :query)
    get("/health", Controller, :health)
    get("/stats", Controller, :stats)
  end
end
