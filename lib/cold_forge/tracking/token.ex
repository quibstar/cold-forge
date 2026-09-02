defmodule ColdForge.Tracking.Token do
  @moduledoc """
  URL-safe random tokens for the links that appear in outgoing mail.

  These are the only identifiers a recipient ever sees, so they're generated
  from `:crypto.strong_rand_bytes/1` rather than derived from a row id —
  guessing one must not be possible.
  """

  @bytes 16

  @doc "A new, unguessable, URL-safe token."
  def generate do
    @bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
