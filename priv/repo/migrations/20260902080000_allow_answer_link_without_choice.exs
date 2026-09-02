defmodule ColdForge.Repo.Migrations.AllowAnswerLinkWithoutChoice do
  use Ecto.Migration

  # A plain "answer a few questions" link has no option attached — nothing to
  # pre-select. It still belongs to a question so we know which campaign's
  # questionnaire to show.
  def change do
    alter table(:answer_links) do
      modify :choice, :string, null: true, from: {:string, null: false}
    end
  end
end
