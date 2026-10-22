defmodule ColdForge.Sourcing.FetcherTest do
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Fetcher

  describe "candidate_urls/2" do
    test "homepage first, then the pages that exist to be written to" do
      assert Fetcher.candidate_urls("https://summitroofing.test") == [
               "https://summitroofing.test/",
               "https://summitroofing.test/contact",
               "https://summitroofing.test/contact-us",
               "https://summitroofing.test/contact.html"
             ]
    end

    test "a site's own path is tried first, because it is already the page we want" do
      urls = Fetcher.candidate_urls("https://hswestmi.test/our-contact-page")

      assert List.first(urls) == "https://hswestmi.test/our-contact-page"
      assert "https://hswestmi.test/" in urls
    end

    test "a bare root path is not duplicated" do
      urls = Fetcher.candidate_urls("https://example.test/")

      assert List.first(urls) == "https://example.test/"
      assert urls == Enum.uniq(urls)
    end

    test "query strings and fragments are dropped from the base" do
      urls = Fetcher.candidate_urls("https://example.test/?utm_source=places#top")

      assert Enum.all?(urls, &(not String.contains?(&1, "utm_source")))
      assert Enum.all?(urls, &(not String.contains?(&1, "#")))
    end

    test "the limit caps how many pages one site can cost us" do
      assert length(Fetcher.candidate_urls("https://example.test", 2)) == 2
      assert length(Fetcher.candidate_urls("https://example.test", 8)) == 8
    end
  end

  describe "the user agent" do
    test "says who we are and how to make us stop" do
      ua = Fetcher.user_agent()

      assert ua =~ "ColdForge"
      # An operator who can reach us blocks us rather than blocking everyone.
      assert ua =~ "mailto:"
      assert ua =~ "robots.txt"
    end
  end

  describe "refusing bad input before any request" do
    test "a non-http scheme is refused" do
      assert {:error, :bad_url} = Fetcher.fetch("ftp://example.test/x")
      assert {:error, :bad_url} = Fetcher.fetch("mailto:someone@example.test")
      assert {:error, :bad_url} = Fetcher.fetch("not a url")
    end
  end
end
