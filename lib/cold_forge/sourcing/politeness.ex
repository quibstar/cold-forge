defmodule ColdForge.Sourcing.Politeness do
  @moduledoc """
  One host, one request at a time, with a gap between them — and a cache of
  each host's robots.txt so it is fetched once rather than once per page.

  Crawling tens of thousands of small business sites is only acceptable if no
  single site notices. Most of these are shared hosting for a roofer with four
  trucks; two requests a second from us is a measurable share of their traffic.
  So the default gap is deliberately slow, and a site asking for more via
  `Crawl-delay` gets it.

  `reserve/2` is a `GenServer.call`, which serialises the check-and-set. Two
  Oban workers reaching the same host in the same instant cannot both be told
  to go: one gets `:ok`, the other gets `{:wait, ms}` and snoozes.
  """

  use GenServer

  alias ColdForge.Sourcing.Robots

  @table :cold_forge_sourcing_politeness
  @robots_table :cold_forge_sourcing_robots

  # Slow on purpose. A crawl that finishes overnight instead of in an hour
  # costs nothing; a crawl that gets our IP blocked costs the whole channel.
  @default_delay_ms 3_000
  # Nobody's robots.txt changes often enough to re-fetch mid-run, and a host
  # that 404s it shouldn't be asked again every page.
  @robots_ttl_ms :timer.hours(12)
  # However politely a site asks, we won't wait longer than this; past it the
  # host simply isn't worth the queue slot.
  @max_delay_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def default_delay_ms, do: @default_delay_ms
  def max_delay_ms, do: @max_delay_ms

  @doc """
  Asks permission to hit `host` now.

  `:ok` means go, and the host is marked as hit this instant. `{:wait, ms}`
  means someone got there first or the gap hasn't elapsed.
  """
  @spec reserve(String.t(), number() | nil) :: :ok | {:wait, non_neg_integer()}
  def reserve(host, crawl_delay_seconds \\ nil) do
    GenServer.call(__MODULE__, {:reserve, host, delay_ms(crawl_delay_seconds)})
  end

  @doc "The parsed robots.txt for a host, or `:miss` if we haven't fetched it."
  @spec robots(String.t()) :: {:ok, Robots.t() | nil} | :miss
  def robots(host) do
    case :ets.lookup(@robots_table, host) do
      [{^host, robots, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, robots}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Caches a host's robots.txt. `nil` records that it has none."
  @spec put_robots(String.t(), Robots.t() | nil) :: :ok
  def put_robots(host, robots) do
    expires_at = System.monotonic_time(:millisecond) + @robots_ttl_ms
    :ets.insert(@robots_table, {host, robots, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets all timing and robots state. For tests."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  defp delay_ms(nil), do: @default_delay_ms

  defp delay_ms(seconds) when is_number(seconds) do
    seconds
    |> Kernel.*(1000)
    |> round()
    |> max(@default_delay_ms)
    |> min(@max_delay_ms)
  end

  ## Server

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@robots_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:reserve, host, delay}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, host) do
      [{^host, next_allowed_at}] when next_allowed_at > now ->
        {:reply, {:wait, next_allowed_at - now}, state}

      _ ->
        :ets.insert(@table, {host, now + delay})
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@robots_table)
    {:reply, :ok, state}
  end
end
