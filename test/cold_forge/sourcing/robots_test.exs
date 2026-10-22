defmodule ColdForge.Sourcing.RobotsTest do
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Robots

  @ua "ColdForge/0.1 (+mailto:kris@affordablestartup.com)"

  defp allowed?(text, path, ua \\ @ua), do: Robots.allowed?(Robots.parse(text), ua, path)

  describe "the basics" do
    test "no file at all means allowed" do
      assert Robots.allowed?(nil, @ua, "/contact")
    end

    test "an empty file allows everything" do
      assert allowed?("", "/contact")
    end

    test "a plain disallow blocks its subtree" do
      text = "User-agent: *\nDisallow: /private"

      refute allowed?(text, "/private")
      refute allowed?(text, "/private/thing")
      assert allowed?(text, "/public")
    end

    test "Disallow with nothing after it is an allow-all, not a block" do
      assert allowed?("User-agent: *\nDisallow:", "/anything")
    end

    test "Disallow: / blocks the site" do
      refute allowed?("User-agent: *\nDisallow: /", "/contact")
    end

    test "comments and blank lines are ignored" do
      text = """
      # welcome, crawlers
      User-agent: *

      Disallow: /admin   # staff only
      """

      refute allowed?(text, "/admin")
      assert allowed?(text, "/contact")
    end

    test "directive names are case-insensitive" do
      refute allowed?("USER-AGENT: *\nDISALLOW: /admin", "/admin")
    end

    test "paths are case-sensitive" do
      text = "User-agent: *\nDisallow: /Admin"

      refute allowed?(text, "/Admin")
      assert allowed?(text, "/admin")
    end
  end

  describe "longest match wins, allow breaks ties" do
    # The rule that matters most to us: a site that blocks everything but
    # names /contact is a site we may read the contact page of.
    test "a specific allow beats a broad disallow" do
      text = "User-agent: *\nDisallow: /\nAllow: /contact"

      assert allowed?(text, "/contact")
      assert allowed?(text, "/contact-us")
      refute allowed?(text, "/pricing")
    end

    test "a specific disallow beats a broad allow" do
      text = "User-agent: *\nAllow: /\nDisallow: /contact/private"

      assert allowed?(text, "/contact")
      refute allowed?(text, "/contact/private")
    end

    test "an equal-length tie goes to allow" do
      text = "User-agent: *\nDisallow: /x\nAllow: /x"
      assert allowed?(text, "/x")
    end
  end

  describe "wildcards and anchors" do
    test "* matches any run of characters" do
      text = "User-agent: *\nDisallow: /*.pdf"

      refute allowed?(text, "/files/brochure.pdf")
      assert allowed?(text, "/files/brochure.html")
    end

    test "$ anchors the end" do
      text = "User-agent: *\nDisallow: /*.php$"

      refute allowed?(text, "/index.php")
      assert allowed?(text, "/index.php?page=2")
    end

    test "a path with regex characters is matched literally" do
      text = "User-agent: *\nDisallow: /a+b(c)"

      refute allowed?(text, "/a+b(c)")
      assert allowed?(text, "/aaab")
    end
  end

  describe "choosing the agent group" do
    @multi """
    User-agent: *
    Disallow: /

    User-agent: ColdForge
    Allow: /
    Disallow: /admin
    """

    test "a group naming us wins over the wildcard group" do
      assert allowed?(@multi, "/contact")
      refute allowed?(@multi, "/admin")
    end

    test "another crawler still gets the wildcard group" do
      refute allowed?(@multi, "/contact", "SomeOtherBot/2.0")
    end

    test "the most specific named agent wins" do
      text = """
      User-agent: bot
      Disallow: /

      User-agent: coldforge
      Allow: /
      """

      # Our UA contains both "bot"? It does not — but a file naming a longer
      # token that matches us must win over a shorter one that also matches.
      assert allowed?(text, "/contact", "coldforge-bot/1.0")
    end

    test "consecutive user-agent lines share one group" do
      text = """
      User-agent: ColdForge
      User-agent: SomeOtherBot
      Disallow: /admin
      """

      refute allowed?(text, "/admin")
      refute allowed?(text, "/admin", "SomeOtherBot/2.0")
      assert allowed?(text, "/contact")
    end

    test "a user-agent line after rules starts a fresh group" do
      text = """
      User-agent: ColdForge
      Disallow: /admin
      User-agent: Other
      Disallow: /
      """

      assert allowed?(text, "/contact")
      refute allowed?(text, "/contact", "Other/1.0")
    end
  end

  describe "crawl delay and sitemaps" do
    test "reads the delay for our group" do
      text = "User-agent: *\nCrawl-delay: 10\nDisallow:"
      assert Robots.crawl_delay(Robots.parse(text), @ua) == 10.0
    end

    test "prefers a delay written for us over the wildcard one" do
      text = """
      User-agent: *
      Crawl-delay: 20

      User-agent: ColdForge
      Crawl-delay: 2
      """

      assert Robots.crawl_delay(Robots.parse(text), @ua) == 2.0
    end

    test "no delay is nil, and a nonsense delay is ignored" do
      assert Robots.crawl_delay(Robots.parse("User-agent: *\nDisallow:"), @ua) == nil
      assert Robots.crawl_delay(Robots.parse("User-agent: *\nCrawl-delay: soon"), @ua) == nil
      assert Robots.crawl_delay(nil, @ua) == nil
    end

    test "collects sitemap lines" do
      text = "Sitemap: https://example.test/sitemap.xml\nUser-agent: *\nDisallow:"
      assert Robots.parse(text).sitemaps == ["https://example.test/sitemap.xml"]
    end
  end

  describe "junk input" do
    test "a page of HTML served as robots.txt does not block us" do
      assert allowed?("<!doctype html><html><body>Not found</body></html>", "/contact")
    end

    test "rules before any user-agent line are ignored" do
      assert allowed?("Disallow: /\nUser-agent: *\nAllow: /", "/contact")
    end
  end
end
