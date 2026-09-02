defmodule ColdForge.Survey.Link do
  @moduledoc """
  The one-click hop from an email to the answer page.

  With a `choice`, it's one person answering one question one way, and the
  landing page pre-selects it. Without one, it's a plain "answer a few
  questions" link and the page starts blank.

  Either way the token is the only identifier, so nothing about the recipient
  is exposed in a URL they might paste somewhere.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "survey_links" do
    field :token, :string
    field :choice, :string

    belongs_to :message, ColdForge.Outreach.Message
    belongs_to :question, ColdForge.Survey.Question, foreign_key: :survey_question_id
    belongs_to :prospect, ColdForge.Outreach.Prospect

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:message_id, :survey_question_id, :prospect_id, :choice])
    # No `:choice`: a plain questionnaire link has no option to pre-select.
    |> validate_required([:message_id, :survey_question_id, :prospect_id])
    |> put_token()
    |> unique_constraint(:token)
  end

  defp put_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, ColdForge.Tracking.Token.generate())
      _ -> changeset
    end
  end
end
