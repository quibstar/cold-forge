defmodule ColdForge.Sourcing.Extractor do
  @moduledoc """
  Pulls published email addresses out of one fetched page, with the evidence
  for each.

  The point is not to find as many addresses as possible. It's to find the ones
  the organisation **published for people to write to**, and to record where
  each came from, so a list can be defended later. Every candidate carries the
  URL it was seen on, how it was presented, and whether the page asked not to
  be solicited.

  Pure: HTML in, candidates out. No network, so it's testable against saved
  pages rather than live sites.
  """

  @type candidate :: %{
          email: String.t(),
          source_url: String.t(),
          presentation: :mailto | :plain_text | :obfuscated | :cloudflare,
          context: String.t() | nil,
          role: String.t() | nil
        }

  @type result :: %{
          candidates: [candidate()],
          no_solicitation: boolean(),
          notice_text: String.t() | nil,
          has_contact_form: boolean()
        }

  # Addresses that are never a person to write to. Checked against the whole
  # address and, for a few, the local part alone.
  @never_mail ~w(
    noreply no-reply donotreply do-not-reply bounce bounces mailer-daemon
    postmaster abuse webmaster@example.com sentry@ wordpress@
  )

  @placeholder_domains ~w(
    example.com example.org example.net domain.com yourdomain.com
    sentry.io wixpress.com squarespace.com godaddy.com sentry.wixpress.com
    email.com yoursite.com test.com localhost
  )

  # A local part that tells you which part of the organisation answers. Ordered
  # best-first: a named function beats a catch-all, because a reply from
  # "adoptions" is a reply from someone whose job this is.
  @roles ~w(
    adoptions adopt rescue intake foster volunteer
    office admin contact info hello inquiries inquiry
    sales owner manager director
  )

  # Phrases that mean "do not send us commercial email". Finding one of these
  # takes the organisation off the email list entirely — it is the only signal
  # on the page that overrides a published address.
  @no_solicitation_phrases [
    "no solicitation",
    "no solicitations",
    "no soliciting",
    "do not solicit",
    "unsolicited commercial",
    "unsolicited email",
    "unsolicited e-mail",
    "no unsolicited",
    "not accept unsolicited",
    "do not sell or share",
    "no vendors",
    "no sales calls",
    "no sales inquiries",
    "solicitations will be"
  ]

  @email_re ~r/\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/

  # "name [at] domain [dot] com" and friends. Deliberately narrow: the
  # separators have to be bracketed or spaced, so ordinary prose doesn't match.
  @obfuscated_re ~r/\b([A-Za-z0-9._%+\-]+)\s*(?:\[at\]|\(at\)|\s+at\s+|&#64;|＠)\s*([A-Za-z0-9.\-]+)\s*(?:\[dot\]|\(dot\)|\s+dot\s+)\s*([A-Za-z]{2,})\b/i

  @doc """
  Everything this page says about how to reach the organisation.

  `source_url` is recorded on every candidate, so a row in the final list can
  always be traced to the page it came from.
  """
  @spec extract(String.t(), String.t()) :: result()
  def extract(html, source_url) when is_binary(html) and is_binary(source_url) do
    doc = Floki.parse_document!(html)

    # Strip the parts of a page that are not prose before reading text out of
    # it. `Floki.text/2` happily returns the contents of <style> and <script>,
    # and an embedded font licence is full of addresses: a real crawl of a
    # Grand Rapids roofer produced the typeface designer's gmail, because the
    # Google Fonts licence sits in their stylesheet. Scripts carry the same
    # hazard with analytics and error-reporting addresses.
    text =
      doc
      |> Floki.filter_out("style")
      |> Floki.filter_out("script")
      |> Floki.filter_out("noscript")
      |> Floki.filter_out(:comment)
      |> Floki.text(sep: " ")
      |> collapse()

    prose = doc |> Floki.filter_out("style") |> Floki.filter_out("script")

    candidates =
      (mailto_candidates(prose, source_url) ++
         cloudflare_candidates(prose, source_url) ++
         plain_text_candidates(text, source_url) ++
         obfuscated_candidates(text, source_url))
      |> Enum.filter(&mailable_address?/1)
      |> dedupe()
      |> Enum.sort_by(&sort_key/1)

    {notice?, notice_text} = no_solicitation(text)

    %{
      candidates: candidates,
      no_solicitation: notice?,
      notice_text: notice_text,
      has_contact_form: contact_form?(doc)
    }
  end

  @doc """
  The one address to write to, or nil.

  Prefers a `mailto:` over text scraped out of prose, and a named function
  (`adoptions@`) over a catch-all (`info@`), because the reply comes faster
  from someone who owns the thing you're asking about.
  """
  @spec best(result()) :: candidate() | nil
  def best(%{no_solicitation: true}), do: nil
  def best(%{candidates: []}), do: nil
  def best(%{candidates: [first | _]}), do: first

  ## Sources

  defp mailto_candidates(doc, url) do
    doc
    |> Floki.find("a[href^='mailto:'], a[href^='MAILTO:']")
    |> Enum.flat_map(fn el ->
      href = el |> Floki.attribute("href") |> List.first() || ""

      case address_from_mailto(href) do
        nil -> []
        email -> [candidate(email, url, :mailto, Floki.text(el))]
      end
    end)
  end

  # Cloudflare's email obfuscation. The address is hex in `data-cfemail` (or in
  # the fragment of an /email-protection link); the first byte is the XOR key
  # for the rest. A human visitor's browser decodes it, so it is published —
  # but it is published guardedly, and the candidate says so.
  defp cloudflare_candidates(doc, url) do
    attrs =
      Floki.attribute(doc, "[data-cfemail]", "data-cfemail") ++
        (doc
         |> Floki.attribute("a[href*='/cdn-cgi/l/email-protection#']", "href")
         |> Enum.map(&(String.split(&1, "#") |> List.last())))

    attrs
    |> Enum.flat_map(fn hex ->
      case decode_cfemail(hex) do
        {:ok, email} -> [candidate(email, url, :cloudflare, nil)]
        :error -> []
      end
    end)
  end

  defp plain_text_candidates(text, url) do
    @email_re
    |> Regex.scan(text)
    |> Enum.flat_map(fn [match | _] -> [candidate(match, url, :plain_text, nil)] end)
  end

  defp obfuscated_candidates(text, url) do
    @obfuscated_re
    |> Regex.scan(text)
    |> Enum.flat_map(fn
      [_, local, domain, tld] ->
        [candidate("#{local}@#{domain}.#{tld}", url, :obfuscated, nil)]

      _ ->
        []
    end)
  end

  ## Decoding

  @doc """
  Decodes a Cloudflare-protected address: hex, where the first byte is the XOR
  key for every byte after it.

  Two West Michigan shelters publish their address this way, so without this
  they read as having none.
  """
  @spec decode_cfemail(String.t()) :: {:ok, String.t()} | :error
  def decode_cfemail(hex) when is_binary(hex) do
    with {:ok, <<key, rest::binary>>} <- decode16(String.trim(hex)),
         decoded = for(<<b <- rest>>, into: "", do: <<Bitwise.bxor(b, key)>>),
         true <- plausible_address?(decoded) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp decode16(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) > 1 -> {:ok, bin}
      _ -> :error
    end
  end

  defp address_from_mailto(href) do
    href
    |> String.replace(~r/^mailto:/i, "")
    |> String.split(["?", "&", ","])
    |> List.first()
    |> URI.decode()
    |> String.trim()
    |> case do
      "" -> nil
      addr -> if plausible_address?(addr), do: addr, else: nil
    end
  end

  ## Notices

  defp no_solicitation(text) do
    down = String.downcase(text)

    case Enum.find(@no_solicitation_phrases, &String.contains?(down, &1)) do
      nil -> {false, nil}
      phrase -> {true, excerpt(text, phrase)}
    end
  end

  # The sentence the phrase sits in, so a reviewer can judge it rather than
  # trusting a keyword. "No soliciting" on a front door sign is not the same as
  # "we do not accept unsolicited commercial email".
  defp excerpt(text, phrase) do
    down = String.downcase(text)
    at = :binary.match(down, phrase) |> then(fn {i, _} -> i end)
    start = max(at - 120, 0)
    length = min(byte_size(text) - start, 280)

    text
    |> binary_part(start, length)
    |> String.trim()
    |> collapse()
  end

  defp contact_form?(doc) do
    inputs = Floki.find(doc, "form input[type='email'], form input[name*='email' i]")
    inputs != []
  end

  ## Filtering

  defp mailable_address?(%{email: email}) do
    down = String.downcase(email)
    [_local, domain] = String.split(down, "@", parts: 2)

    plausible_address?(down) and
      not Enum.any?(@never_mail, &String.contains?(down, &1)) and
      not Enum.member?(@placeholder_domains, domain) and
      not image_filename?(down) and
      not String.ends_with?(domain, [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"])
  end

  # "logo@2x.png" and "sprite@3x.webp" match an email regex. They are not
  # addresses, and a list with one in it gets its sender reputation docked.
  defp image_filename?(address) do
    Regex.match?(~r/@\dx\./, address) or
      Regex.match?(~r/\.(png|jpe?g|gif|webp|svg|css|js)$/, address)
  end

  defp plausible_address?(address) do
    is_binary(address) and
      Regex.match?(~r/^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/, String.trim(address))
  end

  ## Shaping

  defp candidate(email, url, presentation, context) do
    email = email |> String.trim() |> String.downcase()

    %{
      email: email,
      source_url: url,
      presentation: presentation,
      context: context |> normalize_context(),
      role: role_of(email)
    }
  end

  defp normalize_context(nil), do: nil

  defp normalize_context(text) do
    case text |> to_string() |> collapse() |> String.slice(0, 120) |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp role_of(email) do
    local = email |> String.split("@") |> List.first() |> String.downcase()
    Enum.find(@roles, &(&1 == local))
  end

  # Same address found three ways is one address. Keep the strongest evidence:
  # a mailto beats text, and a candidate that carried link text beats one that
  # didn't.
  defp dedupe(candidates) do
    candidates
    |> Enum.group_by(& &1.email)
    |> Enum.map(fn {_email, group} -> Enum.min_by(group, &presentation_rank/1) end)
  end

  defp sort_key(c), do: {role_rank(c.role), presentation_rank(c)}

  defp presentation_rank(%{presentation: p, context: ctx}) do
    base =
      case p do
        :mailto -> 0
        :cloudflare -> 1
        :obfuscated -> 2
        :plain_text -> 3
      end

    base * 2 + if(ctx, do: 0, else: 1)
  end

  defp role_rank(nil), do: length(@roles) + 1

  defp role_rank(role) do
    Enum.find_index(@roles, &(&1 == role)) || length(@roles) + 1
  end

  defp collapse(text), do: String.replace(text, ~r/\s+/u, " ")
end
