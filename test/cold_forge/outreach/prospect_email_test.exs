defmodule ColdForge.Outreach.ProspectEmailTest do
  use ExUnit.Case, async: true

  alias ColdForge.Outreach.Prospect

  describe "clean_email/1" do
    test "decodes a percent-encoded space in front of the address" do
      assert Prospect.clean_email("%20david@roofer.example") == "david@roofer.example"
      assert Prospect.clean_email("%20%20info@roofer.example") == "info@roofer.example"
    end

    test "decodes an encoded @" do
      assert Prospect.clean_email("office%40roofer.example") == "office@roofer.example"
    end

    test "takes off a mailto: prefix, brackets, quotes and trailing punctuation" do
      assert Prospect.clean_email("mailto:info@roofer.example") == "info@roofer.example"
      assert Prospect.clean_email("<info@roofer.example>") == "info@roofer.example"
      assert Prospect.clean_email(~s|"info@roofer.example".|) == "info@roofer.example"
      assert Prospect.clean_email("(info@roofer.example),") == "info@roofer.example"
    end

    test "leaves a clean address and nil alone" do
      assert Prospect.clean_email("Kris.Allen+test@roofer.example") ==
               "Kris.Allen+test@roofer.example"

      assert Prospect.clean_email(nil) == nil
    end

    test "a stray % that isn't an escape stays, for the format check to judge" do
      assert Prospect.clean_email("50%off@roofer.example") == "50%off@roofer.example"
    end
  end

  describe "changeset" do
    test "stores the cleaned address" do
      changeset =
        Prospect.changeset(%Prospect{}, %{
          project_id: Ecto.UUID.generate(),
          email: " %20david@roofer.example "
        })

      assert Ecto.Changeset.get_change(changeset, :email) == "david@roofer.example"
      assert changeset.valid?
    end

    test "an encoded space in the middle still fails the format check" do
      changeset =
        Prospect.changeset(%Prospect{}, %{
          project_id: Ecto.UUID.generate(),
          email: "da%20vid@roofer.example"
        })

      refute changeset.valid?
      assert {"must be a valid email", _} = changeset.errors[:email]
    end
  end
end
