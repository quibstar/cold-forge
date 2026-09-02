defmodule ColdForgeWeb.TrackingHTML do
  @moduledoc """
  The unsubscribe pages.

  These render standalone — no app layout, no nav, no branding beyond the
  project name. Someone who wants out should see one button, not a website.
  """
  use ColdForgeWeb, :html

  embed_templates "tracking_html/*"

  @doc """
  Centered card shared by all three unsubscribe states, so the page a recipient
  lands on looks the same whether the link worked or not.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def unsub_shell(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 flex items-center justify-center px-4 py-12">
      <div class="w-full max-w-md">
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h1 class="text-xl font-semibold">{@title}</h1>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>
    """
  end
end
