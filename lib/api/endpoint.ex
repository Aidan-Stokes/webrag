defmodule AONCrawler.API.Endpoint do
  @moduledoc """
  Phoenix endpoint for AONCrawler API.

  This module defines the HTTP endpoint that handles requests to the API.
  It uses Cowboy as the underlying HTTP server.
  """

  use Phoenix.Endpoint, otp_app: :aoncrawler

  plug(AONCrawler.API.Router)
end
