defmodule ColdForge.Outreach.Prospect do
  @moduledoc """
  Someone we might email. Status tracks the terminal outcomes that should stop
  outreach — replied, bounced, unsubscribed — so the scheduler can skip them
  without consulting every campaign they're in.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(new active replied bounced unsubscribed completed)

  schema "prospects" do
    field :email, :string
    field :first_name, :string
    field :last_name, :string
    field :company, :string
    field :title, :string
    field :industry, :string
    field :phone, :string
    field :website, :string
    field :custom_fields, :map, default: %{}
    # Form-only: the one-per-line text the operator edits, parsed into
    # `custom_fields` before cast. Kept virtual so a half-typed line survives a
    # validate round trip instead of snapping back to the saved map.
    field :custom_fields_text, :string, virtual: true
    field :source, :string
    field :notes, :string
    field :status, :string, default: "new"
    field :unsubscribed_at, :utc_datetime
    field :bounced_at, :utc_datetime
    field :replied_at, :utc_datetime
    field :unsubscribe_token, :string
    # Calling state, denormalised so the call queue is one indexed query.
    field :next_call_at, :utc_datetime
    field :last_called_at, :utc_datetime
    field :call_attempts, :integer, default: 0
    field :do_not_call, :boolean, default: false

    belongs_to :project, ColdForge.Outreach.Project
    has_many :enrollments, ColdForge.Outreach.Enrollment

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(prospect, attrs) do
    prospect
    |> cast(prepare_custom_fields(prospect, attrs), [
      :project_id,
      :email,
      :first_name,
      :last_name,
      :company,
      :title,
      :industry,
      :phone,
      :website,
      :custom_fields,
      :custom_fields_text,
      :source,
      :notes,
      :status
    ])
    |> validate_required([:project_id])
    |> validate_reachable()
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email"
    )
    |> validate_inclusion(:status, @statuses)
    |> put_unsubscribe_token()
    |> unique_constraint([:project_id, :email],
      message: "is already a prospect on this project"
    )
    |> check_constraint(:email, name: :email_or_phone, message: "or phone is required")
    |> foreign_key_constraint(:project_id)
  end

  # Two editors write this one map: the one-per-line textarea for short extras,
  # and a textarea each for the per-business call scripts, which are prose and
  # cannot survive a `name: value` line. `CallScripts` is what they agree on —
  # without it, saving the form you were shown would silently drop the fields
  # it didn't show you.
  defp prepare_custom_fields(prospect, attrs) do
    attrs
    |> ColdForge.MergeFields.parse("custom_fields")
    |> then(&ColdForge.Outreach.CallScripts.put_custom_fields(prospect, &1))
  end

  @doc """
  Every merge tag this prospect resolves, and what it resolves to.

  The point is answering "why did the email say *that*" without reading the
  renderer: a blank here is a tag that will fall back, and a fallback nobody
  wrote is an empty gap in somebody's inbox.
  """
  def merge_values(%__MODULE__{} = prospect) do
    built_in = [
      {"first_name", prospect.first_name},
      {"last_name", prospect.last_name},
      {"full_name", display_name(prospect)},
      {"email", prospect.email},
      {"company", prospect.company},
      {"title", prospect.title},
      {"industry", prospect.industry},
      {"phone", prospect.phone},
      {"website", prospect.website}
    ]

    custom =
      prospect.custom_fields
      |> Kernel.||(%{})
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()

    built_in ++ custom
  end

  @doc """
  Whether the number we hold is actually a number.

  Hand-built lists put "See website", "— look up —" and bare domains in the
  phone column. A `tel:` link around one of those is dead but looks live, so
  the presence of digits is what decides whether we offer to dial it.
  """
  # Seven digits, the shortest number anyone can actually dial. Counted after
  # the brackets, spaces and dashes come off, since every list punctuates
  # differently.
  def dialable?(%__MODULE__{phone: phone}) when is_binary(phone),
    do: phone |> String.replace(~r/\D/, "") |> String.length() >= 7

  def dialable?(_), do: false

  @doc """
  The fit grade carried on the prospect, or `nil`.

  A `custom_fields` value rather than a column because every list that arrives
  grades differently, and the grade is one word of somebody's judgment, not a
  fact about the business. `fit_rank/1` is what the call queue sorts on.
  """
  def fit(%__MODULE__{} = prospect), do: custom_field(prospect, "fit")

  @doc """
  One `custom_fields` value, trimmed, or `nil`.

  The column defaults to `%{}` but an older row can still hold a null, and a
  screen that reads a field straight off the map crashes on one of those.
  """
  def custom_field(%__MODULE__{custom_fields: fields}, key) when is_map(fields),
    do: presence(Map.get(fields, key))

  def custom_field(_prospect, _key), do: nil

  # The words different lists use for the same three grades. Data rather than a
  # case statement: it is a vocabulary, and it grows every time a list arrives
  # with its own idea of how to say "call this one first".
  @fit_ranks %{
    "high" => 0,
    "a" => 0,
    "medium" => 1,
    "med" => 1,
    "b" => 1,
    "verify" => 2,
    "low" => 2,
    "c" => 2
  }

  @unranked 3

  @doc """
  Sort order for a fit grade, best first.

  Anything unrecognised sorts last: an ungraded row belongs at the bottom of a
  call list, not silently in the middle of it. `ColdForge.Calling.queue/2`
  repeats this ranking in SQL, because the queue is limited and an ordering
  applied after the limit picks the wrong fifty.
  """
  def fit_rank(fit) do
    Map.get(@fit_ranks, fit |> to_string() |> String.downcase() |> String.trim(), @unranked)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # Email or phone, not necessarily both. A phone-only prospect can be called
  # but never enrolled in a campaign — see `mailable?/1`.
  defp validate_reachable(changeset) do
    if blank?(get_field(changeset, :email)) and blank?(get_field(changeset, :phone)) do
      add_error(changeset, :email, "or phone is required")
    else
      changeset
    end
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp put_unsubscribe_token(changeset) do
    case get_field(changeset, :unsubscribe_token) do
      nil -> put_change(changeset, :unsubscribe_token, ColdForge.Tracking.Token.generate())
      _ -> changeset
    end
  end

  @doc "Display name, falling back to the email when we only have an address."
  def display_name(%__MODULE__{} = prospect) do
    case String.trim("#{prospect.first_name} #{prospect.last_name}") do
      "" -> prospect.email || prospect.company || prospect.phone
      name -> name
    end
  end

  @doc """
  Whether this prospect may still be emailed. Suppression is checked separately
  by `ColdForge.Outreach.suppressed?/1` — that list is global.
  """
  # `completed` is mailable: finishing a sequence without answering is not an
  # opt-out, and a later campaign — often for a different idea — may be exactly
  # what lands. Opt-outs are the suppression list's job, not this status's.
  #
  # And it needs an address: a phone-only prospect is reachable, but only by the
  # call queue.
  def mailable?(%__MODULE__{email: email, status: status}) do
    is_binary(email) and email != "" and status in ["new", "active", "completed"]
  end
end
