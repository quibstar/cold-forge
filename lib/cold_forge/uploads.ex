defmodule ColdForge.Uploads do
  @moduledoc """
  Where uploaded files live.

  A configurable directory rather than `priv/static/uploads`, because a release
  puts `priv` inside a versioned path — `.../lib/cold_forge-0.1.0/priv` — so
  anything written there is baked into the image and disappears the next time
  the version changes. A logo that vanishes on deploy takes every already-sent
  email's branding with it.

  In production this points at a mounted volume. In development it falls back
  to `priv/static/uploads`, which is convenient and gitignored.
  """

  @doc "The directory uploads are written to and served from."
  def dir do
    case Application.get_env(:cold_forge, :uploads_dir) do
      nil -> Path.join([:code.priv_dir(:cold_forge), "static", "uploads"])
      dir -> dir
    end
  end

  @doc "The directory for one kind of upload, created if it isn't there yet."
  def dir!(subdirectory) do
    path = Path.join(dir(), subdirectory)
    File.mkdir_p!(path)
    path
  end
end
