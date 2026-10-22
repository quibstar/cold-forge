defmodule ColdForge.Sourcing.Robots do
  @moduledoc """
  A robots.txt parser, and the question it exists to answer: may we fetch this
  path?

  Deliberately strict about the parts that matter and deliberately small about
  the rest. The rules implemented are the ones the major crawlers agree on:

    * groups are formed by consecutive `User-agent` lines, so several agents
      can share one block
    * the most specific matching agent wins; `*` is the fallback, and a group
      naming us beats it even if the `*` group is more permissive
    * `*` matches any run of characters and a trailing `$` anchors the end
    * **longest match wins**, and on an equal-length tie `Allow` beats
      `Disallow` — which is the rule that makes `Allow: /contact` usable under
      `Disallow: /`
    * an empty `Disallow:` is an explicit allow-all, not a block
    * directive names are case-insensitive, paths are case-sensitive

  Unparsable or missing robots.txt means allowed: that is the convention, and
  treating a 404 as a block would make most of the web uncrawlable. A 5xx is a
  different matter and the caller decides — see `ColdForge.Sourcing.Fetcher`.
  """

  defstruct groups: %{}, crawl_delays: %{}, sitemaps: []

  @type t :: %__MODULE__{
          groups: %{String.t() => [{:allow | :disallow, String.t()}]},
          crawl_delays: %{String.t() => number()},
          sitemaps: [String.t()]
        }

  @doc "Parses robots.txt. Anything unrecognised is ignored rather than fatal."
  @spec parse(String.t()) :: t()
  def parse(text) when is_binary(text) do
    text
    |> String.split(["\n", "\r\n", "\r"])
    |> Enum.map(&strip_comment/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({%__MODULE__{}, [], false}, &reduce_line/2)
    |> then(fn {robots, _agents, _in_rules} -> robots end)
  end

  defp strip_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp reduce_line(line, {robots, agents, in_rules} = acc) do
    case split_directive(line) do
      {"user-agent", value} ->
        agent = String.downcase(value)
        # A User-agent line after rules starts a new group; one directly after
        # another User-agent line joins the same group.
        agents = if in_rules, do: [agent], else: [agent | agents]
        {ensure_groups(robots, agents), agents, false}

      {"disallow", value} ->
        # "Disallow:" with nothing after it means nothing is disallowed.
        rule = if value == "", do: {:allow, "/"}, else: {:disallow, value}
        {add_rule(robots, agents, rule), agents, true}

      {"allow", value} when value != "" ->
        {add_rule(robots, agents, {:allow, value}), agents, true}

      {"crawl-delay", value} ->
        {add_delay(robots, agents, value), agents, true}

      {"sitemap", value} ->
        {%{robots | sitemaps: robots.sitemaps ++ [value]}, agents, in_rules}

      _ ->
        acc
    end
  end

  defp split_directive(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> {name |> String.trim() |> String.downcase(), String.trim(value)}
      _ -> :skip
    end
  end

  defp ensure_groups(robots, agents) do
    groups = Enum.reduce(agents, robots.groups, &Map.put_new(&2, &1, []))
    %{robots | groups: groups}
  end

  defp add_rule(robots, [], _rule), do: robots

  defp add_rule(robots, agents, rule) do
    groups =
      Enum.reduce(agents, robots.groups, fn agent, acc ->
        Map.update(acc, agent, [rule], &(&1 ++ [rule]))
      end)

    %{robots | groups: groups}
  end

  defp add_delay(robots, agents, value) do
    case Float.parse(value) do
      {seconds, _} when seconds >= 0 ->
        delays = Enum.reduce(agents, robots.crawl_delays, &Map.put(&2, &1, seconds))
        %{robots | crawl_delays: delays}

      _ ->
        robots
    end
  end

  @doc """
  Whether `user_agent` may fetch `path`.

  `path` is the path and query, not a full URL.
  """
  @spec allowed?(t() | nil, String.t(), String.t()) :: boolean()
  def allowed?(nil, _user_agent, _path), do: true

  def allowed?(%__MODULE__{} = robots, user_agent, path) do
    case rules_for(robots, user_agent) do
      [] ->
        true

      rules ->
        rules
        |> Enum.map(fn {kind, pattern} -> {kind, pattern, match_length(pattern, path)} end)
        |> Enum.reject(fn {_kind, _pattern, length} -> is_nil(length) end)
        |> case do
          [] ->
            true

          matches ->
            # Longest wins; allow breaks a tie.
            {kind, _pattern, _length} =
              Enum.max_by(matches, fn {kind, _p, length} ->
                {length, if(kind == :allow, do: 1, else: 0)}
              end)

            kind == :allow
        end
    end
  end

  @doc "The crawl delay this agent should honour, in seconds, or nil."
  @spec crawl_delay(t() | nil, String.t()) :: number() | nil
  def crawl_delay(nil, _user_agent), do: nil

  def crawl_delay(%__MODULE__{} = robots, user_agent) do
    case matching_agent(robots.crawl_delays, user_agent) do
      nil -> nil
      agent -> Map.get(robots.crawl_delays, agent)
    end
  end

  defp rules_for(robots, user_agent) do
    case matching_agent(robots.groups, user_agent) do
      nil -> []
      agent -> Map.get(robots.groups, agent, [])
    end
  end

  # The longest agent token that appears in our user-agent string, else "*".
  # Longest so that a file naming both "bot" and "coldforge" gives us the
  # rules written for us.
  defp matching_agent(map, user_agent) do
    down = String.downcase(user_agent)

    named =
      map
      |> Map.keys()
      |> Enum.reject(&(&1 == "*"))
      |> Enum.filter(&String.contains?(down, &1))
      |> Enum.sort_by(&(-String.length(&1)))
      |> List.first()

    cond do
      named -> named
      Map.has_key?(map, "*") -> "*"
      true -> nil
    end
  end

  # How many characters of `path` the pattern matched, or nil for no match.
  # Length is measured on the pattern so that `/` scores 1 and `/contact`
  # scores 8, which is what makes "longest wins" mean "most specific wins".
  defp match_length(pattern, path) do
    {regex_source, score} = compile(pattern)

    case Regex.compile("^" <> regex_source) do
      {:ok, regex} -> if Regex.match?(regex, path), do: score, else: nil
      {:error, _} -> nil
    end
  end

  defp compile(pattern) do
    anchored? = String.ends_with?(pattern, "$")
    body = if anchored?, do: String.trim_trailing(pattern, "$"), else: pattern

    source =
      body
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    source = if anchored?, do: source <> "$", else: source
    {source, String.length(body)}
  end
end
