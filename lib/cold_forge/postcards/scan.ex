defmodule ColdForge.Postcards.Scan do
  @moduledoc """
  One scan of a postcard's QR code. As with flyers, a scan isn't a person — a
  reload is another one — so the user agent is kept to check an odd count.
  """
  use ColdForge.Schema

  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "postcard_scans" do
    field :user_agent, :string

    belongs_to :postcard, ColdForge.Postcards.Postcard

    timestamps()
  end
end
