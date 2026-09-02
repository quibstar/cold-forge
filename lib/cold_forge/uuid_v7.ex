defmodule ColdForge.UUIDv7 do
  @moduledoc """
  UUIDv7 primary keys — RFC 9562.

  Version 7 rather than the version 4 Ecto's `:binary_id` generates, because a
  v7 is time-ordered: its first 48 bits are a millisecond timestamp. Inserts
  therefore land at the right-hand edge of the primary key index instead of
  scattering across it, which is the difference between a B-tree that stays
  compact and one that fragments. `ORDER BY id` is also chronological to the
  millisecond — ids minted inside the same millisecond tie in arbitrary order,
  since the bits after the timestamp are random rather than a counter.

  Layout, most significant bit first:

      48 bits  unix timestamp, milliseconds
       4 bits  version (7)
      12 bits  random
       2 bits  variant (0b10)
      62 bits  random

  Postgres 18 has a native `uuidv7()`, but generation stays here: Ecto needs
  the id before the insert to build associations, and a value the database
  invents can't be used for that.
  """
  use Ecto.Type

  @impl true
  def type, do: :uuid

  @impl true
  defdelegate cast(value), to: Ecto.UUID

  @impl true
  defdelegate dump(value), to: Ecto.UUID

  @impl true
  defdelegate load(value), to: Ecto.UUID

  @impl true
  def autogenerate, do: generate()

  @doc "A new UUIDv7, in the usual hyphenated string form."
  def generate do
    <<rand_a::12, rand_b::62, _rest::6>> = :crypto.strong_rand_bytes(10)

    <<System.system_time(:millisecond)::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Ecto.UUID.load!()
  end

  @doc """
  The millisecond timestamp encoded in a v7, as a `DateTime`.

  Useful when you have an id and not the row — and a reminder that a v7 leaks
  its creation time, so one should never stand in for a secret. The tokens in
  outgoing mail are generated separately for exactly that reason.
  """
  def timestamp(uuid) when is_binary(uuid) do
    with {:ok, <<ms::48, _::binary>>} <- Ecto.UUID.dump(uuid) do
      DateTime.from_unix(ms, :millisecond)
    end
  end
end
