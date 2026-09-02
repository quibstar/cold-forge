defmodule ColdForge.Schema do
  @moduledoc """
  The base every schema in this app uses: `Ecto.Schema` with UUIDv7 keys.

  Central so the two settings can't disagree — a schema with a UUID primary key
  and an integer foreign key type is a runtime error waiting for whichever
  association gets used first.
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, ColdForge.UUIDv7, autogenerate: true}
      @foreign_key_type ColdForge.UUIDv7
    end
  end
end
