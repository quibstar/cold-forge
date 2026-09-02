defmodule ColdForge.Survey do
  @moduledoc """
  Questions asked inside campaigns, and the answers that come back.

  The point of asking is the answer, not the click — so nothing here records an
  answer from a link being fetched. Mail scanners at Gmail, Outlook and every
  corporate security appliance fetch the URLs in an email to check them, and a
  one-click answer that committed on GET would fill this table with responses
  nobody gave. The email's link only *proposes* an answer; the answer page
  pre-selects it and the person confirms.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Enrollment, Message, Prospect}
  alias ColdForge.Survey.Survey, as: Sheet
  alias ColdForge.Repo
  alias ColdForge.Survey.{Link, Question, Response}

  ## Surveys

  def list_surveys(project_id) do
    Sheet
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], asc: s.name)
    |> preload(:questions)
    |> Repo.all()
  end

  def get_survey!(id), do: Sheet |> Repo.get!(id) |> Repo.preload(:questions)

  def create_survey(attrs) do
    %Sheet{} |> Sheet.changeset(attrs) |> Repo.insert()
  end

  def update_survey(%Sheet{id: id}, attrs) do
    # Re-read rather than casting onto the struct handed in. That struct may
    # carry questions produced by a previous `cast_assoc`, and Ecto refuses to
    # cast an association twice off the same data — it can't track the changes.
    # A plain (or even forced) preload doesn't clear that state; a fresh load
    # does.
    Sheet
    |> Repo.get!(id)
    |> Repo.preload(:questions)
    |> Sheet.changeset(attrs)
    |> Repo.update()
  end

  def delete_survey(%Sheet{} = survey), do: Repo.delete(survey)

  def change_survey(%Sheet{} = survey, attrs \\ %{}) do
    survey |> Repo.preload(:questions) |> Sheet.changeset(attrs)
  end

  ## Questions

  def list_questions(survey_id) do
    Question
    |> where([q], q.survey_id == ^survey_id)
    |> order_by([q], asc: q.position)
    |> Repo.all()
  end

  def get_question!(id), do: Repo.get!(Question, id)

  def create_question(%Sheet{} = survey, attrs) do
    position = next_position(survey.id)

    %Question{}
    |> Question.changeset(Map.merge(attrs, %{"survey_id" => survey.id, "position" => position}))
    |> Repo.insert()
  end

  defp next_position(survey_id) do
    max =
      Question
      |> where([q], q.survey_id == ^survey_id)
      |> select([q], max(q.position))
      |> Repo.one()

    (max || 0) + 1
  end

  def update_question(%Question{} = question, attrs) do
    question |> Question.changeset(attrs) |> Repo.update()
  end

  def change_question(%Question{} = question, attrs \\ %{}),
    do: Question.changeset(question, attrs)

  @doc "Deletes a question and closes the gap, keeping positions a dense 1..n."
  def delete_question(%Question{} = question) do
    Repo.transaction(fn ->
      Repo.delete!(question)

      from(q in Question,
        where: q.survey_id == ^question.survey_id and q.position > ^question.position
      )
      |> Repo.update_all(inc: [position: -1])

      :ok
    end)
  end

  ## Answer links — built while a message is being rendered

  @doc """
  Creates one link per clickable answer and returns `{answer, token}` pairs for
  the renderer to write into the body.
  """
  def build_answer_links(
        %Message{} = message,
        %Question{} = question,
        %Prospect{} = prospect,
        answers
      ) do
    Enum.map(answers, fn answer ->
      {:ok, link} = insert_link(message, question, prospect, answer)
      {answer, link.token}
    end)
  end

  @doc """
  A link with no answer attached, for kinds one click can't express — pick-any
  and free text. The page opens with nothing pre-selected.
  """
  def build_open_link(%Message{} = message, %Question{} = question, %Prospect{} = prospect) do
    insert_link(message, question, prospect, nil)
  end

  defp insert_link(message, question, prospect, choice) do
    %Link{}
    |> Link.changeset(%{
      message_id: message.id,
      survey_question_id: question.id,
      prospect_id: prospect.id,
      choice: choice
    })
    |> Repo.insert()
  end

  def get_answer_link(token) when is_binary(token) do
    Link
    |> Repo.get_by(token: token)
    |> Repo.preload([:prospect, message: [enrollment: :campaign], question: [survey: :project]])
  end

  def get_answer_link(_), do: nil

  @doc """
  Every question on the campaign an answer link belongs to, with whatever this
  prospect has already answered.

  The answer page shows all of them: somebody who clicked has already shown
  they're willing to engage, and that's the cheapest moment to ask a second
  question.
  """
  def questionnaire(%Link{} = link) do
    questions = list_questions(link.question.survey_id)

    existing =
      Response
      |> where([r], r.prospect_id == ^link.prospect_id)
      |> where([r], r.survey_question_id in ^Enum.map(questions, & &1.id))
      |> Repo.all()
      |> Map.new(&{&1.survey_question_id, &1})

    %{questions: questions, responses: existing}
  end

  ## Answers

  @doc """
  Records answers for one prospect and stops their campaign if it's set to.

  `answers` is `%{question_id => %{"choice" => ..., "text" => ...}}`. Blank
  entries are skipped rather than stored: a submitted form with nothing in it
  is not a data point, and counting it would flatter the response rate.
  """
  def record_answers(%Link{} = link, answers) when is_map(answers) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      saved =
        answers
        |> Enum.map(fn {question_id, values} ->
          upsert_response(link, to_int(question_id), values, now)
        end)
        |> Enum.reject(&is_nil/1)

      if saved != [], do: after_answering(link, now)

      saved
    end)
  end

  defp upsert_response(link, question_id, values, now) do
    question = Repo.get(Question, question_id)

    attrs =
      %{
        survey_question_id: question_id,
        prospect_id: link.prospect_id,
        message_id: link.message_id,
        answered_at: now
      }
      |> Map.merge(answer_attrs(question, values))

    if Response.answered?(attrs) do
      # Coming back to change your mind should correct the record rather than
      # add a second data point, hence the upsert on (question, prospect).
      case %Response{}
           |> Response.changeset(attrs)
           |> Repo.insert(
             on_conflict:
               {:replace,
                [:choice, :choices, :number, :text, :answered_at, :message_id, :updated_at]},
             conflict_target: [:survey_question_id, :prospect_id],
             returning: true
           ) do
        {:ok, response} -> response
        {:error, _changeset} -> nil
      end
    else
      nil
    end
  end

  # Each kind reads a different field off the form, and writing an answer into
  # the wrong column would make it invisible to the tally.
  defp answer_attrs(nil, _values), do: %{}

  defp answer_attrs(%Question{kind: "multi"}, values) do
    %{
      choices: values |> Map.get("choices", []) |> List.wrap() |> Enum.reject(&(&1 == "")),
      text: values["text"]
    }
  end

  defp answer_attrs(%Question{kind: kind}, values) when kind in ~w(rating nps) do
    %{number: parse_int(values["number"]), text: values["text"]}
  end

  defp answer_attrs(%Question{kind: "text"}, values), do: %{text: values["text"]}

  defp answer_attrs(%Question{}, values),
    do: %{choice: presence(values["choice"]), text: values["text"]}

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(value), do: if(String.trim(value) == "", do: nil, else: value)

  # Answering is engagement. Sending the next cold follow-up to somebody who
  # just told you something is the own-goal this whole feature exists to avoid.
  defp after_answering(%Link{} = link, now) do
    # The campaign comes from the message that carried the link, not from the
    # survey — the same survey may be asked by several campaigns, and only the
    # one they were actually sent should stop.
    campaign = link.message && link.message.enrollment && link.message.enrollment.campaign

    if is_nil(campaign) do
      :ok
    else
      stop_or_note(campaign, link, now)
    end
  end

  defp stop_or_note(campaign, link, now) do
    query =
      from(e in Enrollment,
        where: e.campaign_id == ^campaign.id and e.prospect_id == ^link.prospect_id
      )

    if campaign.stop_on_answer do
      Repo.update_all(query,
        set: [
          status: "stopped",
          stopped_reason: "answered",
          next_send_at: nil,
          answered_at: now
        ]
      )
    else
      Repo.update_all(query, set: [answered_at: now])
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)

  ## Reading the results

  @doc """
  Results for one question, shaped by its kind.

  Options and scale points with no answers are kept in the tally — "nobody
  picked this" is a finding, and dropping the row hides it.
  """
  def results(%Question{} = question) do
    responses =
      Response
      |> where([r], r.survey_question_id == ^question.id)
      |> order_by([r], desc: r.answered_at)
      |> preload(:prospect)
      |> Repo.all()

    %{
      tally: tally(question, responses),
      average: average(question, responses),
      total: length(responses),
      comments: Enum.filter(responses, &present?(&1.text))
    }
  end

  defp tally(%Question{kind: "multi"} = question, responses) do
    counts = responses |> Enum.flat_map(& &1.choices) |> Enum.frequencies()
    Enum.map(question.options, &%{label: &1, count: Map.get(counts, &1, 0)})
  end

  defp tally(%Question{kind: kind} = question, responses) when kind in ~w(rating nps) do
    counts = responses |> Enum.map(& &1.number) |> Enum.frequencies()

    question
    |> Question.scale()
    |> Enum.map(&%{label: to_string(&1), count: Map.get(counts, &1, 0)})
  end

  defp tally(%Question{kind: "text"}, _responses), do: []

  defp tally(%Question{} = question, responses) do
    counts = responses |> Enum.map(& &1.choice) |> Enum.frequencies()
    Enum.map(question.options, &%{label: &1, count: Map.get(counts, &1, 0)})
  end

  # Only meaningful on a numeric scale — an average of "Double-booking" and
  # "No-shows" is not a number.
  defp average(%Question{kind: kind}, responses) when kind in ~w(rating nps) do
    numbers = responses |> Enum.map(& &1.number) |> Enum.reject(&is_nil/1)

    case numbers do
      [] -> nil
      _ -> Float.round(Enum.sum(numbers) / length(numbers), 1)
    end
  end

  defp average(%Question{}, _responses), do: nil

  defp present?(nil), do: false
  defp present?(value), do: String.trim(value) != ""

  @doc "How many distinct people have answered anything on this survey."
  def answered_count(survey_id) do
    from(r in Response,
      join: q in assoc(r, :question),
      where: q.survey_id == ^survey_id,
      select: count(r.prospect_id, :distinct)
    )
    |> Repo.one()
  end

  @doc """
  The question an email puts in front of somebody — the first one in the survey
  it links to, or `nil` when the email links to no survey.
  """
  def email_question(nil), do: nil

  def email_question(survey_id) do
    survey_id |> list_questions() |> List.first()
  end

  @doc "Marks the prospect as engaged, the same way a reply does."
  def mark_engaged(%Prospect{} = prospect) do
    Outreach.mark_replied(prospect)
  end
end
