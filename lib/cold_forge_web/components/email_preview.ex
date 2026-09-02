defmodule ColdForgeWeb.EmailPreview do
  @moduledoc """
  Shows an email exactly as it will be sent — merge tags resolved, links
  tokenised, signature and compliance footer attached.

  Shared by every screen that composes or inspects mail, so the editor, the
  step list and the test send can't drift into showing three different things.
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

  The phone/desktop toggle is pure `JS` — no server round trip, because the
  preview is something you flick between while reading, not a decision worth a
  message.
  """
  attr :id, :string, default: "email-preview"
  attr :subject, :string, default: ""
  attr :body, :string, default: ""
  attr :branded, :boolean, default: false
  attr :prospect, :map, required: true
  attr :project, :map, required: true
  attr :question, :map, default: nil

  attr :full_page_url, :string,
    default: nil,
    doc: "when set, offers the email as a standalone page at full width"

  attr :class, :string, default: "h-fit lg:sticky lg:top-20"
  attr :height, :string, default: "h-[32rem]"

  attr :variant, :atom,
    default: :card,
    values: [:card, :bare],
    doc: "`:bare` drops the card wrapper and heading for use inside a modal, which supplies both"

  def email_preview(assigns) do
    preview =
      Renderer.preview_message(
        assigns.subject || "",
        assigns.body || "",
        assigns.prospect,
        assigns.project,
        branded: assigns.branded,
        question: assigns.question
      )

    assigns = assign(assigns, :preview, preview)

    ~H"""
    <div class={[@variant == :card && "card bg-base-100 shadow-sm", @class]}>
      <div class={[@variant == :card && "card-body"]}>
        <%!-- With no heading in `:bare` mode the controls are the row's only
        child, so `justify-between` would strand them on the left. --%>
        <div class={[
          "flex items-center gap-2 flex-wrap",
          if(@variant == :card, do: "justify-between", else: "justify-end")
        ]}>
          <%!-- A modal supplies its own title and close button; rendering a
          second heading here would duplicate one and collide with the other. --%>
          <h2 :if={@variant == :card} class="card-title text-base">Preview</h2>

          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/50">
              as {Prospect.display_name(@prospect)}
            </span>
            <.link
              :if={@full_page_url}
              href={@full_page_url}
              target="_blank"
              rel="noopener"
              class="btn btn-xs btn-ghost"
              title="Open at full width in a new tab"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
            </.link>
            <div class="join">
              <button
                type="button"
                id={"#{@id}-desktop"}
                phx-click={show_desktop(@id)}
                class="join-item btn btn-xs btn-active"
                title="Desktop width"
              >
                <.icon name="hero-computer-desktop" class="size-3.5" />
              </button>
              <button
                type="button"
                id={"#{@id}-mobile"}
                phx-click={show_mobile(@id)}
                class="join-item btn btn-xs"
                title="Phone width"
              >
                <.icon name="hero-device-phone-mobile" class="size-3.5" />
              </button>
            </div>
          </div>
        </div>

        <div class="border border-base-300 rounded-lg overflow-hidden">
          <div class="px-4 py-2 bg-base-200 text-sm border-b border-base-300">
            <div class="text-xs text-base-content/50">
              From {@project.from_name} &lt;{@project.from_email}&gt;
            </div>
            <div class="font-medium truncate">{@preview.subject}</div>
          </div>

          <%!-- The frame sits on the same grey the branded template paints, so
          narrowing to phone width reads as a device rather than a gap. --%>
          <div class="bg-[#e8e8ea] flex justify-center">
            <iframe
              id={"#{@id}-frame"}
              title="Email preview"
              sandbox=""
              srcdoc={@preview.html}
              class={["w-full bg-white transition-[max-width] duration-200", @height]}
            ></iframe>
          </div>
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

  # 375px is an iPhone's viewport — the width most cold email is actually read at.
  defp show_mobile(id) do
    JS.set_attribute({"style", "max-width:375px"}, to: "##{id}-frame")
    |> JS.add_class("btn-active", to: "##{id}-mobile")
    |> JS.remove_class("btn-active", to: "##{id}-desktop")
  end

  defp show_desktop(id) do
    JS.remove_attribute("style", to: "##{id}-frame")
    |> JS.add_class("btn-active", to: "##{id}-desktop")
    |> JS.remove_class("btn-active", to: "##{id}-mobile")
  end
end
