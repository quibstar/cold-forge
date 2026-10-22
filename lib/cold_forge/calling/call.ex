defmodule ColdForge.Calling.Call do
  @moduledoc """
  One attempt to reach somebody by phone.

  Every attempt is recorded, not just the ones that connected — four no-answers
  before a pickup is the normal shape of this work, and a history that only
  shows conversations makes it look like nothing happened.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @outcomes ~w(no_answer gatekeeper voicemail connected interested demo_sent
               not_now not_interested do_not_call wrong_number)

  # The taxonomy the pain-point research workbook rolls up by. Kept as one list
  # so cold-call pains can be counted beside the ones mined from reviews — in
  # that workbook the script's categories and the summary's had drifted apart,
  # and every mismatched row silently counted as zero.
  @categories [
    "Pricing/Contracts",
    "Support",
    "Mobile/Field reliability",
    "Integrations",
    "Reporting",
    "Complexity/Usability",
    "Onboarding",
    "Communication",
    "Estimating/Billing",
    "Pipeline/Workflow",
    "UI/UX",
    "Performance",
    "Account/Ownership",
    "Other"
  ]

  schema "calls" do
    field :outcome, :string
    field :voicemail_script, :integer
    field :notes, :string
    field :called_at, :utc_datetime
    field :next_call_at, :utc_datetime

    # What they said, in the shape the research workbook counts. Filled in
    # during the same thirty seconds as the notes, which is why they are one
    # form rather than a panel somebody opens later.
    field :current_software, :string
    field :what_they_like, :string
    field :pain, :string
    field :category, :string
    field :severity, :integer
    field :switch_objection, :string

    belongs_to :prospect, ColdForge.Outreach.Prospect

    timestamps(type: :utc_datetime)
  end

  def outcomes, do: @outcomes

  @doc "The pain categories, matching the research workbook's taxonomy."
  def categories, do: @categories

  @doc "How an outcome reads in the interface."
  def label("no_answer"), do: "No answer"
  def label("gatekeeper"), do: "Blocked by gatekeeper"
  def label("voicemail"), do: "Left voicemail"
  def label("connected"), do: "Spoke to them"
  def label("interested"), do: "Interested — booked or wants a look"
  def label("demo_sent"), do: "Sent the demo"
  def label("not_now"), do: "Not now"
  def label("not_interested"), do: "Not interested"
  def label("do_not_call"), do: "Do not call"
  def label("wrong_number"), do: "Wrong number"
  def label(other), do: other

  @doc "Outcomes that end the pursuit rather than scheduling another attempt."
  def closing?(outcome), do: outcome in ~w(not_interested do_not_call wrong_number)

  @fields [
    :prospect_id,
    :outcome,
    :voicemail_script,
    :notes,
    :called_at,
    :next_call_at,
    :current_software,
    :what_they_like,
    :pain,
    :category,
    :severity,
    :switch_objection
  ]

  @doc false
  def changeset(call, attrs) do
    call
    |> cast(attrs, @fields)
    |> validate_required([:prospect_id, :outcome, :called_at])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:voicemail_script, 1..4)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:severity, 1..5)
    |> foreign_key_constraint(:prospect_id)
  end
end
