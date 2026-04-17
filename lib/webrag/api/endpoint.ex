defmodule WebRAG.API.Endpoint do
  @moduledoc """
  Phoenix endpoint for WebRAG API.

  This module defines the HTTP endpoint that handles requests to the API.
  It uses Cowboy as the underlying HTTP server.
  """

  use Phoenix.Endpoint, otp_app: :webrag

  plug(WebRAG.API.Router)
end
