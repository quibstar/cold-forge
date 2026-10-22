defmodule ColdForge.Repo.Migrations.CallPainDebrief do
  use Ecto.Migration

  # What was said, in the shape the pain-point research workbook rolls up by.
  # These came across with ExteriorPro's cold-call list: an outcome tells you
  # whether a call happened, and nothing about why the shop would or would not
  # switch, which is the only part of a cold call worth keeping.
  #
  # `what_they_like` earns its place because it is the question everyone skips.
  # It says what a switch must not take away.
  #
  # `severity` is self-assessed during a call you are also trying to win, so it
  # is not an independent measurement. A rough ranking beats none; read it as
  # "how loudly did they say it".
  def change do
    alter table(:calls) do
      add :current_software, :string
      add :what_they_like, :text
      add :pain, :text
      add :category, :string
      add :severity, :integer
      add :switch_objection, :string
    end

    # The rollups ask "how many calls landed in Pricing/Contracts", which reads
    # every call with a category and nothing else.
    create index(:calls, [:category])
  end
end
