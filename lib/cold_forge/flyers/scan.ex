defmodule ColdForge.Flyers.Scan do
  @moduledoc """
  One scan of a flyer's QR code.

  Scans aren't people: a reload is another scan, and link previewers fetch any
  public URL. The user agent is kept so an odd-looking count can be checked.
  """
  use ColdForge.Schema

  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "flyer_scans" do
    field :user_agent, :string

    belongs_to :placement, ColdForge.Flyers.Placement

    timestamps()
  end
end
