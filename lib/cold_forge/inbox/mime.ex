defmodule ColdForge.Inbox.Mime do
  @moduledoc """
  The readable text of a raw email.

  SES hands over the whole message — headers, MIME boundaries, quoted-printable
  and all — and a reply shown or forwarded like that is unreadable. This pulls
  out the plain-text part, falling back to an HTML part with the tags stripped,
  and failing that, to everything after the headers. A reply is never dropped
  for being hard to parse: the worst case is that it reads a little rough.
  """

  @doc "The plain-text body of `raw`, a complete RFC 5322 message."
  def text_body(raw) when is_binary(raw) do
    case decode(raw) do
      {:ok, part} -> find_text(part) || after_headers(raw)
      :error -> after_headers(raw)
    end
  end

  def text_body(_), do: nil

  @doc "Whether `value` looks like a whole message rather than just a body."
  def raw_message?(value) when is_binary(value),
    do: Regex.match?(~r/^(MIME-Version|Content-Type|Received|Return-Path):/mi, value)

  def raw_message?(_), do: false

  # `encoding: :none` keeps each part's bytes as sent instead of converting
  # charsets, which needs the iconv NIF this release doesn't ship. Replies are
  # overwhelmingly UTF-8 already; anything else reads slightly off rather than
  # failing.
  defp decode(raw) do
    {:ok, :mimemail.decode(raw, [{:encoding, :none}])}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp find_text(part), do: plain(part) || html(part)

  defp plain({"text", "plain", _headers, _params, body}) when is_binary(body), do: trim(body)

  defp plain({"multipart", _sub, _headers, _params, parts}) when is_list(parts),
    do: Enum.find_value(parts, &plain/1)

  defp plain(_), do: nil

  defp html({"text", "html", _headers, _params, body}) when is_binary(body) do
    body |> Floki.parse_document!() |> Floki.text(sep: "\n") |> trim()
  rescue
    _ -> nil
  end

  defp html({"multipart", _sub, _headers, _params, parts}) when is_list(parts),
    do: Enum.find_value(parts, &html/1)

  defp html(_), do: nil

  defp after_headers(raw) do
    case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
      [_headers, body] -> trim(body)
      [only] -> trim(only)
    end
  end

  defp trim(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
