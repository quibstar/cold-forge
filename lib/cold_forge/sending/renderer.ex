defmodule ColdForge.Sending.Renderer do
  @moduledoc """
  Turns a campaign step into the exact text a prospect receives.

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

  alias ColdForge.Outreach.{Message, Project, Prospect, CampaignStep}
  alias ColdForge.Repo
  alias ColdForge.Tracking.TrackedLink

  @tag_pattern ~r/\{\{\s*([a-zA-Z0-9_]+)\s*(?:\|([^}]*))?\}\}/

  @doc """
  Applies merge tags to a step's subject and body. URLs are still raw at this
  point — they can't be tokenised until the message row exists.
  """
  def render_step(%CampaignStep{} = step, %Prospect{} = prospect, %Project{} = project) do
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

    body =
      body
      |> append_signature(project)
      |> String.replace("{{unsubscribe_url}}", unsubscribe_url)

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
  The project's sign-off, added unless the body already ends with one.

  This is the branding that belongs in cold mail: a person's name and details,
  not a letterhead. Skipped when the author has clearly written their own —
  a doubled signature reads worse than none.
  """
  def append_signature(body, %Project{signature: signature}) when signature in [nil, ""],
    do: body

  def append_signature(body, %Project{signature: signature}) do
    trimmed = String.trim(signature)

    if String.contains?(body, trimmed) do
      body
    else
      String.trim_trailing(body) <> "\n\n" <> trimmed
    end
  end

  @doc """
  Everything a message will look like, without writing anything to the database.

  Used by the preview pane and the test send. Link tokens are fake — creating
  real ones would mean a `tracked_links` row per keystroke, and a click count
  polluted by your own previews.
  """
  def preview_message(subject, body, %Prospect{} = prospect, %Project{} = project, opts \\ []) do
    base_url = opts[:base_url] || ColdForgeWeb.Endpoint.url()
    branded? = Keyword.get(opts, :branded, false)

    subject = apply_tags(subject, merge_values(prospect, project))

    text =
      body
      |> apply_tags(merge_values(prospect, project))
      |> fake_tracked_links(base_url)
      |> append_footer(prospect, project, base_url)

    %{
      subject: subject,
      text: text,
      html: html_body(text, preview_pixel(base_url), project, branded?)
    }
  end

  # Mirrors rewrite_links/3 exactly, minus the inserts — so what you see in the
  # preview is the shape of what goes out.
  defp fake_tracked_links(body, base_url) do
    body
    |> extract_urls()
    |> Enum.reject(&internal?(&1, base_url))
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.with_index()
    |> Enum.reduce(body, fn {url, index}, acc ->
      String.replace(acc, url, "#{base_url}/c/preview#{index}")
    end)
  end

  defp preview_pixel(base_url), do: "#{base_url}/o/preview.png"

  @doc """
  A minimal HTML part: paragraphs, linkified URLs, and the open pixel.

  Plain by default. The plain-text part is the real message, and an HTML
  template around a cold email is the clearest signal that it was sent in bulk.
  `branded: true` opts into the wrapper for blasts, where the recipient already
  knows who you are.
  """
  def to_html(text, %Message{} = message, base_url, project \\ nil, branded? \\ false) do
    html_body(text, open_pixel_url(base_url, message), project, branded?)
  end

  defp html_body(text, pixel_url, project, branded?) do
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

    pixel = ~s(<img src="#{pixel_url}" width="1" height="1" alt="">)

    if branded? and project do
      branded_html(paragraphs, pixel, project)
    else
      plain_html(paragraphs, pixel)
    end
  end

  defp plain_html(paragraphs, pixel) do
    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111">
    #{paragraphs}
    </div>
    #{pixel}
    """
  end

  # Table-based and inline-styled because mail clients are not browsers —
  # Outlook ignores most of a stylesheet and flexbox outright.
  defp branded_html(paragraphs, pixel, %Project{} = project) do
    accent = project.brand_color || "#0f766e"

    logo =
      if project.logo_url in [nil, ""] do
        ~s(<span style="font-size:18px;font-weight:700;color:#fff">#{escape(project.from_name)}</span>)
      else
        ~s(<img src="#{project.logo_url}" alt="#{escape(project.name)}" height="32" style="height:32px;display:block;border:0">)
      end

    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f4f4f5;padding:24px 0">
      <tr><td align="center">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:100%;background:#fff;border-radius:8px;overflow:hidden">
          <tr><td style="background:#{accent};padding:20px 24px">#{logo}</td></tr>
          <tr><td style="padding:24px;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111">
            #{paragraphs}
          </td></tr>
        </table>
      </td></tr>
    </table>
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
