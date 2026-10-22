defmodule ColdForgeWeb.RadioChoicesTest do
  @moduledoc """
  Fewer than five options are radio buttons, not a select: a select hides the
  options you didn't pick, and with so few there's room to show them all.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ColdForgeWeb.CoreComponents

  defp choice(options, prompt \\ nil) do
    assigns = %{options: options, prompt: prompt}

    rendered_to_string(~H"""
    <.input type="choice" id="pick" name="pick" value={nil} prompt={@prompt} options={@options} />
    """)
  end

  test "four options are radios" do
    html = choice([{"A", "a"}, {"B", "b"}, {"C", "c"}, {"D", "d"}])

    assert length(Regex.scan(~r/type="radio"/, html)) == 4
    refute html =~ "<select"
  end

  test "five options are a select" do
    html = choice(~w(a b c d e))

    assert html =~ "<select"
    refute html =~ ~s(type="radio")
  end

  test "a prompt counts as an option" do
    assert choice(~w(a b c d), "— none —") =~ "<select"
    assert choice(~w(a b c), "— none —") =~ ~s(type="radio")
  end

  test "radios mark the current value" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input
        type="radios"
        id="mode"
        name="mode"
        value="radius"
        options={[{"In a state", "state"}, {"Near a town", "radius"}]}
      />
      """)

    assert html =~ ~r{id="mode_radius"[^>]*checked}
    refute html =~ ~r{id="mode_state"[^>]*checked}
  end
end
