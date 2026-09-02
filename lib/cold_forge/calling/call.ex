defmodule ColdForge.Calling.Call do
  @moduledoc """
  One attempt to reach somebody by phone.

  Every attempt is recorded, not just the ones that connected — four no-answers
  before a pickup is the normal shape of this work, and a history that only
  shows conversations makes it look like nothing happened.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @outcomes ~w(no_answer voicemail connected interested not_now not_interested do_not_call wrong_number)

  schema "calls" do
    field :outcome, :string
    field :voicemail_script, :integer
    field :notes, :string
    field :called_at, :utc_datetime
    field :next_call_at, :utc_datetime

    belongs_to :prospect, ColdForge.Outreach.Prospect

    timestamps(type: :utc_datetime)
  end

  def outcomes, do: @outcomes

  @doc "How an outcome reads in the interface."
  def label("no_answer"), do: "No answer"
  def label("voicemail"), do: "Left voicemail"
  def label("connected"), do: "Spoke to them"
  def label("interested"), do: "Interested — booked or wants a look"
  def label("not_now"), do: "Not now"
  def label("not_interested"), do: "Not interested"
  def label("do_not_call"), do: "Do not call"
  def label("wrong_number"), do: "Wrong number"
  def label(other), do: other

  @doc "Outcomes that end the pursuit rather than scheduling another attempt."
  def closing?(outcome), do: outcome in ~w(not_interested do_not_call wrong_number)

  @doc false
  def changeset(call, attrs) do
    call
    |> cast(attrs, [:prospect_id, :outcome, :voicemail_script, :notes, :called_at, :next_call_at])
    |> validate_required([:prospect_id, :outcome, :called_at])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:voicemail_script, 1..4)
    |> foreign_key_constraint(:prospect_id)
  end
end
