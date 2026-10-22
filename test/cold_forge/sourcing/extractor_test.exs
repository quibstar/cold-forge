defmodule ColdForge.Sourcing.ExtractorTest do
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Extractor

  # Encodes the way Cloudflare does, so the test proves the decoder against the
  # real scheme rather than against a string I typed out by hand.
  defp cfemail(address, key) do
    [key | for(<<b <- address>>, do: Bitwise.bxor(b, key))]
    |> :erlang.list_to_binary()
    |> Base.encode16(case: :lower)
  end

  defp page(body), do: "<!doctype html><html><body>#{body}</body></html>"

  describe "mailto links" do
    test "takes the address and the link's own words" do
      html = page(~s|<a href="mailto:adoptions@rescue.test">Email adoptions</a>|)

      assert %{candidates: [c]} = Extractor.extract(html, "https://rescue.test/contact")
      assert c.email == "adoptions@rescue.test"
      assert c.presentation == :mailto
      assert c.context == "Email adoptions"
      assert c.role == "adoptions"
      assert c.source_url == "https://rescue.test/contact"
    end

    test "drops the subject and other mailto parameters" do
      html =
        page(~s|<a href="mailto:info@rescue.test?subject=Pound%20Buddies%20Inquiry">Email</a>|)

      assert %{candidates: [c]} = Extractor.extract(html, "https://rescue.test")
      assert c.email == "info@rescue.test"
    end

    test "survives a percent-encoded address and uppercase scheme" do
      html = page(~s|<a href="MAILTO:office%40rescue.test">Office</a>|)

      assert %{candidates: [c]} = Extractor.extract(html, "https://rescue.test")
      assert c.email == "office@rescue.test"
    end
  end

  describe "Cloudflare obfuscation" do
    test "decodes data-cfemail" do
      hex = cfemail("office@harbor.example", 0x2A)

      html =
        page(~s|<a href="#" class="__cf_email__" data-cfemail="#{hex}">[email protected]</a>|)

      assert %{candidates: [c]} = Extractor.extract(html, "https://harbor.example/contact")
      assert c.email == "office@harbor.example"
      assert c.presentation == :cloudflare
    end

    test "decodes the address out of an email-protection link fragment" do
      hex = cfemail("adoptions@hs.example", 0x5B)
      html = page(~s|<a href="/cdn-cgi/l/email-protection##{hex}">Email us</a>|)

      assert %{candidates: [c]} = Extractor.extract(html, "https://hs.example")
      assert c.email == "adoptions@hs.example"
    end

    test "garbage hex yields nothing rather than a junk address" do
      html = page(~s|<span data-cfemail="zzzz">x</span>|)
      assert %{candidates: []} = Extractor.extract(html, "https://rescue.test")
    end
  end

  describe "text and obfuscated text" do
    test "finds an address written in prose" do
      html = page("<p>Write to us at jancekfarm@farm.test for the next litter.</p>")

      assert %{candidates: [c]} = Extractor.extract(html, "https://farm.test")
      assert c.email == "jancekfarm@farm.test"
      assert c.presentation == :plain_text
    end

    test "reassembles name [at] domain [dot] com" do
      html = page("<p>kris [at] rescue [dot] test</p>")

      assert %{candidates: [c]} = Extractor.extract(html, "https://farm.test")
      assert c.email == "kris@rescue.test"
      assert c.presentation == :obfuscated
    end
  end

  describe "what must never reach a send list" do
    test "retina image filenames are not addresses" do
      html = page(~s|<img src="logo@2x.png"><p>logo@2x.png</p>|)
      assert %{candidates: []} = Extractor.extract(html, "https://rescue.test")
    end

    test "noreply and postmaster are dropped" do
      for addr <- ~w(noreply@real.example no-reply@real.example postmaster@real.example) do
        html = page(~s|<a href="mailto:#{addr}">x</a>|)
        assert %{candidates: []} = Extractor.extract(html, "https://real.example"), addr
      end
    end

    test "platform and placeholder domains are dropped" do
      for addr <- ~w(a@example.com b@sentry.wixpress.com c@yourdomain.com) do
        html = page(~s|<a href="mailto:#{addr}">x</a>|)
        assert %{candidates: []} = Extractor.extract(html, "https://real.example"), addr
      end
    end
  end

  describe "no-solicitation notices" do
    test "a notice is reported with the sentence around it" do
      html = page("<p>We do not accept unsolicited commercial email from vendors.</p>
                   <a href='mailto:info@rescue.test'>Contact</a>")

      result = Extractor.extract(html, "https://rescue.test/contact")

      assert result.no_solicitation
      assert result.notice_text =~ "unsolicited commercial"
    end

    test "a notice overrides a published address, so best/1 returns nothing" do
      html = page("<p>No solicitations please.</p><a href='mailto:info@rescue.test'>Contact</a>")

      result = Extractor.extract(html, "https://rescue.test")

      assert result.candidates != [], "the address is still reported as seen"
      refute Extractor.best(result), "but it must not be offered as mailable"
    end

    test "an ordinary page reports no notice" do
      html = page("<p>Adopt a dog today.</p>")
      refute Extractor.extract(html, "https://rescue.test").no_solicitation
    end
  end

  describe "choosing between several addresses" do
    test "a named function beats a catch-all" do
      html =
        page("""
        <a href="mailto:info@rescue.test">General</a>
        <a href="mailto:adoptions@rescue.test">Adoptions</a>
        <a href="mailto:volunteer@rescue.test">Volunteer</a>
        """)

      result = Extractor.extract(html, "https://rescue.test/contact")
      assert Extractor.best(result).email == "adoptions@rescue.test"
    end

    test "a mailto beats the same address scraped from prose" do
      html =
        page("""
        <p>Reach us at office@rescue.test any time.</p>
        <a href="mailto:office@rescue.test">Email the office</a>
        """)

      assert %{candidates: [c]} = Extractor.extract(html, "https://rescue.test")
      assert c.presentation == :mailto, "deduped to the stronger evidence"
      assert c.context == "Email the office"
    end
  end

  describe "contact forms" do
    test "a form with an email field is noted, so a form-only org becomes a call target" do
      html = page(~s|<form><input type="email" name="email"></form>|)

      result = Extractor.extract(html, "https://rescue.test/contact")

      assert result.has_contact_form
      assert result.candidates == []
      refute Extractor.best(result)
    end
  end
end
