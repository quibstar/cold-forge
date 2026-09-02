defmodule ColdForge.Sending.Renderer do
  @moduledoc """
  Turns a sequence step into the exact text a prospect receives.

  Three passes, in order:

    1. **Merge tags** — `{{first_name}}`, with an optional fallback after a pipe
       (`{{first_name|there}}`) so an incomplete row degrades to "Hi there"
       rather than "Hi ".
    2. **Link rewriting** — every outbound URL in the body is replaced with a
       Cold Forge `/c/:token` redirect, which is what makes a click attributable
       to a specific send. Links already pointing at Cold Forge (the unsubscribe
       link) are left alone.
    3. **Footer** — unsubscribe link and postal address, appended unless the
       body already places `{{unsubscribe_url}}` itself.

  Bodies are authored as plain text on purpose. A cold email that arrives as a
  designed HTML template reads as bulk mail; the HTML part here is a minimal
  paragraph-wrapped version of the same words.
  """

  alias ColdForge.Outreach.{Message, Project, Prospect, SequenceStep}
  alias ColdForge.Repo
  alias ColdForge.Tracking.TrackedLink

  @tag_pattern ~r/\{\{\s*([a-zA-Z0-9_]+)\s*(?:\|([^}]*))?\}\}/

  @doc """
  Applies merge tags to a step's subject and body. URLs are still raw at this
  point — they can't be tokenised until the message row exists.
  """
  def render_step(%SequenceStep{} = step, %Prospect{} = prospect, %Project{} = project) do
    values = merge_values(prospect, project)

    %{
      subject: apply_tags(step.subject, values),
      body: apply_tags(step.body, values)
    }
  end

  @doc "Renders arbitrary text against a prospect — used by the step previewer."
  def preview(text, %Prospect{} = prospect, %Project{} = project) do
    apply_tags(text, merge_values(prospect, project))
  end

  defp merge_values(%Prospect{} = prospect, %Project{} = project) do
    # Custom fields are merged under the built-ins so an imported column named
    # "company" can't shadow the real one.
    custom =
      prospect.custom_fields
      |> Kernel.||(%{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    Map.merge(custom, %{
      "first_name" => prospect.first_name,
      "last_name" => prospect.last_name,
      "full_name" => Prospect.display_name(prospect),
      "email" => prospect.email,
      "company" => prospect.company,
      "title" => prospect.title,
      "phone" => prospect.phone,
      "website" => prospect.website,
      "sender_name" => project.from_name,
      "project" => project.name,
      # The whole point of the redirect: authors write {{link}}, and it becomes
      # a tracked hop out to the project's landing page.
      "link" => project.landing_url
    })
  end

  defp apply_tags(nil, _values), do: ""

  defp apply_tags(text, values) do
    Regex.replace(@tag_pattern, text, fn _match, key, fallback ->
      case Map.get(values, key) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> fallback
            trimmed -> trimmed
          end

        nil ->
          fallback

        value ->
          to_string(value)
      end
    end)
  end

  @doc """
  Replaces outbound URLs in `body` with tracked redirects, inserting a
  `tracked_links` row per distinct destination.

  Returns the rewritten body. Must run after the message is inserted, since
  each link belongs to a specific message.
  """
  def rewrite_links(body, %Message{} = message, base_url) do
    body
    |> extract_urls()
    |> Enum.reject(&internal?(&1, base_url))
    |> Enum.uniq()
    # Longest first: replacing "https://site.com" before "https://site.com/demo"
    # would rewrite the prefix *inside* the longer URL and leave a mangled tail.
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.reduce(body, fn url, acc ->
      case create_tracked_link(message, url) do
        {:ok, link} -> String.replace(acc, url, tracked_url(base_url, link.token))
        # A link we can't tokenise still has to reach the recipient — sending
        # the raw URL loses the click event, but losing the email is worse.
        {:error, _} -> acc
      end
    end)
  end

  # Trailing punctuation is almost always sentence punctuation rather than part
  # of the URL, so it's trimmed back off the match.
  defp extract_urls(body) do
    ~r/https?:\/\/[^\s<>"')\]]+/
    |> Regex.scan(body)
    |> Enum.map(fn [url] -> String.trim_trailing(url, ".") |> String.trim_trailing(",") end)
  end

  # Our own links (unsubscribe, and anything already tokenised) must not be
  # wrapped again — that would redirect Cold Forge to Cold Forge.
  defp internal?(url, base_url) do
    String.starts_with?(url, base_url)
  end

  defp create_tracked_link(message, url) do
    %TrackedLink{}
    |> TrackedLink.changeset(%{message_id: message.id, destination_url: url})
    |> Repo.insert()
  end

  defp tracked_url(base_url, token), do: "#{base_url}/c/#{token}"

  @doc """
  Appends the unsubscribe line and postal address, unless the body already
  contains an unsubscribe link.

  CAN-SPAM requires both a working opt-out and a physical address in commercial
  mail, so this is not optional decoration — it runs on every send.
  """
  def append_footer(body, %Prospect{} = prospect, %Project{} = project, base_url) do
    unsubscribe_url = unsubscribe_url(base_url, prospect)

    body = String.replace(body, "{{unsubscribe_url}}", unsubscribe_url)

    if String.contains?(body, unsubscribe_url) do
      body
    else
      address = project.postal_address |> Kernel.||("") |> String.trim()
      address_line = if address == "", do: "", else: "\n#{address}"

      String.trim_trailing(body) <>
        "\n\n---\n" <>
        "Not interested? Unsubscribe here and I won't email you again: #{unsubscribe_url}" <>
        address_line
    end
  end

  def unsubscribe_url(base_url, %Prospect{} = prospect),
    do: "#{base_url}/u/#{prospect.unsubscribe_token}"

  def open_pixel_url(base_url, %Message{} = message),
    do: "#{base_url}/o/#{message.open_token}.png"

  @doc """
  A minimal HTML part: paragraphs, linkified URLs, and the open pixel. No
  styling — the plain-text part is the real message.
  """
  def to_html(text, %Message{} = message, base_url) do
    paragraphs =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map_join("\n", fn para ->
        para
        |> escape()
        |> linkify()
        |> String.replace("\n", "<br>\n")
        |> then(&"<p>#{&1}</p>")
      end)

    pixel = ~s(<img src="#{open_pixel_url(base_url, message)}" width="1" height="1" alt="">)

    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111">
    #{paragraphs}
    </div>
    #{pixel}
    """
  end

  # Escaping happens before linkifying so a URL's own characters survive, but
  # any angle brackets the author typed can't inject markup.
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp linkify(text) do
    Regex.replace(~r/https?:\/\/[^\s<>"')\]]+/, text, fn url ->
      ~s(<a href="#{url}">#{url}</a>)
    end)
  end
end
