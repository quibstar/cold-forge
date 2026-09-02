defmodule ColdForgeWeb.EmailPreview do
  @moduledoc """
  Shows an email exactly as it will be sent — merge tags resolved, links
  tokenised, signature and compliance footer attached.

  Shared by every screen that composes mail, so the drip editor and the blast
  composer can't drift into showing two different things.
  """
  use ColdForgeWeb, :html

  alias ColdForge.Outreach.Prospect
  alias ColdForge.Sending.Renderer

  @doc """
  Renders the real HTML in a sandboxed iframe rather than injecting it into the
  page.

  The point is to see the mail's own markup; letting it inherit the admin's
  stylesheet would show you something the recipient never gets. `sandbox=""`
  also means a pasted `<script>` in a body can't run against the admin.
  """
  attr :subject, :string, default: ""
  attr :body, :string, default: ""
  attr :branded, :boolean, default: false
  attr :prospect, :map, required: true
  attr :project, :map, required: true
  attr :class, :string, default: "h-fit lg:sticky lg:top-20"

  def email_preview(assigns) do
    preview =
      Renderer.preview_message(
        assigns.subject || "",
        assigns.body || "",
        assigns.prospect,
        assigns.project,
        branded: assigns.branded
      )

    assigns = assign(assigns, :preview, preview)

    ~H"""
    <div class={["card bg-base-100 shadow-sm", @class]}>
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-base">Preview</h2>
          <span class="text-xs text-base-content/50">
            as {Prospect.display_name(@prospect)}
          </span>
        </div>

        <div class="border border-base-300 rounded-lg overflow-hidden">
          <div class="px-4 py-2 bg-base-200 text-sm border-b border-base-300">
            <div class="text-xs text-base-content/50">
              From {@project.from_name} &lt;{@project.from_email}&gt;
            </div>
            <div class="font-medium truncate">{@preview.subject}</div>
          </div>

          <iframe
            title="Email preview"
            sandbox=""
            srcdoc={@preview.html}
            class="w-full h-[26rem] bg-white"
          ></iframe>
        </div>

        <details class="mt-2">
          <summary class="text-xs text-base-content/50 cursor-pointer">
            Plain-text part — what most cold mail is judged on
          </summary>
          <pre class="text-xs whitespace-pre-wrap font-mono mt-2 p-3 bg-base-200 rounded-lg max-h-64 overflow-y-auto">{@preview.text}</pre>
        </details>
      </div>
    </div>
    """
  end
end
