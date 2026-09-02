defmodule ColdForgeWeb.AdminLive.Guide do
  @moduledoc """
  How the app works and how not to get your domain burned.

  Lives in the app rather than a README because the decisions it describes —
  daily caps, plain text, what a tracked link actually does — are ones you make
  while looking at these screens.
  """
  use ColdForgeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "How this works")
     |> assign(:page_subtitle, "The short version, and the parts that bite.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <.card title="The shape of it">
        <p>
          A <strong>project</strong>
          is one idea — its own from-address, its own landing page, its own people.
          Inside a project you have <strong>prospects</strong>
          (the pool) and <strong>campaigns</strong>
          (emails plus the people who get them).
        </p>
        <p>
          A campaign with one email is a single send. Add more emails with delays
          and they become follow-ups. There's no setting for which — the emails
          decide.
        </p>
      </.card>

      <.card title="What happens when someone clicks">
        <p>
          You write <code>{"{{link}}"}</code>. What actually ships is a link back
          to Cold Forge:
        </p>
        <pre class="text-xs bg-base-200 rounded-lg p-3 overflow-x-auto"><code>coldforge/c/lUGpMvm8…&#10;   ↓  click recorded&#10;https://exteriorpro.io/demo?cf=lUGpMvm8…</code></pre>
        <p>
          The hop through Cold Forge is what makes a click attributable to one
          specific email to one specific person. The <code>cf=</code>
          parameter rides out with them, so your landing page can tie a form fill
          back to the send that caused it.
        </p>
      </.card>

      <.card title="Unsubscribes are permanent and global">
        <p>
          Every email carries an unsubscribe link. Using it marks the person
          unsubscribed, stops every campaign they're in, and adds them to <.link
            navigate={~p"/admin/suppressions"}
            class="link"
          >Do not contact</.link>.
        </p>
        <p>
          That list is <strong>global, not per project</strong>. Someone who opts
          out of one idea will never appear in the next one's list — including
          through a CSV import, which checks it before adding anyone.
        </p>
      </.card>

      <.card title="Why the emails look plain">
        <p>
          Cold email that arrives as a designed HTML template reads as bulk mail,
          and lands in Promotions or Spam. The most effective cold email looks
          like something a person typed in Gmail.
        </p>
        <p>
          So campaigns send plain text by default, with your <strong>signature</strong>
          from the project settings — that's the branding that works here. The
          <strong>Branded HTML</strong>
          switch exists for sends to people who already know you (an announcement,
          a case study). Leave it off for anything cold.
        </p>
      </.card>

      <.card title="Pacing — the setting that saves your domain">
        <p>
          Each campaign has a daily cap and a send window. A campaign of 2,000
          people at 50/day goes out over forty days. That's deliberate: sending
          2,000 cold emails in an hour from a new domain is how a sending domain
          gets blocked, usually permanently.
        </p>
        <ul class="list-disc pl-5 space-y-1">
          <li>New domain? Start at 20–30/day and climb over several weeks.</li>
          <li>Keep bounces under 5% and complaints under 0.1% — AWS enforces both.</li>
          <li>
            Send inside business hours in the recipient's timezone. Cold mail at
            3am announces itself as a robot.
          </li>
        </ul>
      </.card>

      <.card title="Reading the numbers">
        <p>
          <strong>Clicked</strong>
          is the number worth trusting. <strong>Opened</strong>
          is not — Gmail and Outlook fetch the tracking pixel before a human sees
          anything, so opens are inflated and sometimes entirely machine. Cold
          Forge records them, but never uses them to stop or branch a campaign.
        </p>
        <p>
          The signal that matters most isn't in this app at all: replies. When
          someone gets back to you, mark them <strong>Replied</strong>
          on the prospect list — it stops their campaigns so a follow-up doesn't
          interrupt a live conversation.
        </p>
      </.card>

      <.card title="Merge tags">
        <p>
          <code>{"{{first_name}}"}</code>
          <code>{"{{last_name}}"}</code>
          <code>{"{{company}}"}</code>
          <code>{"{{title}}"}</code>
          <code>{"{{sender_name}}"}</code>
          <code>{"{{link}}"}</code>
        </p>
        <p>
          Add a fallback after a pipe: <code>{"{{first_name|there}}"}</code>
          renders "there" when the field is empty. Use it on every tag — "Hi ,"
          is worse than no personalisation at all.
        </p>
        <p>
          Any CSV column you don't map is kept too, so a <code>Roof Type</code>
          column becomes <code>{"{{roof_type}}"}</code>.
        </p>
      </.card>

      <.card title="Knowing when someone replies">
        <p>
          Point an inbound mail provider at <code>/inbound/&lt;your secret&gt;</code>
          and replies land in the Replies tab, stop that person's campaign, and
          mark them replied. With SES that means an MX record for a subdomain,
          a receipt rule, and an SNS subscription posting to that URL.
        </p>
        <p>
          Matching is exact where it can be: every email carries a <code>Message-ID</code>
          we generate, and a reply quotes it back in <code>In-Reply-To</code>. When
          a mail client strips that, we fall back to the sender's address — still
          a reply, just not tied to a specific email, and the Replies tab labels
          those so a run of them tells you the header isn't surviving.
        </p>
        <p>
          Out-of-office notices and bounce reports are recorded but change
          nothing. Somebody on holiday hasn't answered you, and dropping them
          out of a campaign for it would lose you the lead.
        </p>
        <p>
          Until that's wired up, the <strong>Replied</strong>
          button on the prospect list does the same job by hand.
        </p>
      </.card>

      <.card title="Which domain to send from">
        <p>
          Not the one carrying your real business mail. Cold outreach damages
          sending reputation even when you do everything right — some people
          hit "spam" regardless — and you want that landing somewhere you could
          abandon, not on the domain your customers reply to.
        </p>
        <p>
          A subdomain is the cheap version and it is good enough: <code>go.yourcompany.com</code>. It inherits the parent domain's age,
          it resolves to a real business if a filter goes looking, and the root
          stays clean.
        </p>
        <p>
          Avoid <code>marketing.</code>
          and <code>track.</code>
          — the host shows
          up in every link a recipient hovers, and those two announce bulk mail
          before the email has said anything. <code>go.</code>
          and <code>links.</code>
          read as nothing at all, which is the point.
        </p>
        <p>
          <strong>Send from the same subdomain the links point at.</strong>
          A from-address on one domain and tracked links on another is the shape
          of a phishing email, and it is a common self-inflicted wound.
        </p>

        <div class="not-prose">
          <p class="font-medium text-base-content mb-1">On the sending subdomain</p>
          <ul class="list-disc pl-5 space-y-1">
            <li>
              <code>A</code>
              or <code>CNAME</code>
              → wherever Cold Forge runs, so tracked links, unsubscribes and survey pages resolve
            </li>
            <li><code>MX</code> → your inbound provider, which is what makes reply detection work</li>
            <li>The <code>CNAME</code> records SES gives you for DKIM</li>
            <li><code>TXT</code>: <code>v=spf1 include:amazonses.com ~all</code></li>
          </ul>

          <p class="font-medium text-base-content mt-3 mb-1">On the root domain</p>
          <p>
            <code>v=DMARC1; p=none; sp=none; rua=mailto:dmarc@yourcompany.com</code>
          </p>
          <p class="text-base-content/60">
            <code>sp=none</code>
            is the part people miss: subdomains inherit the
            root's policy, so tightening <code>p</code>
            to <code>quarantine</code>
            later would silently start failing your
            outreach until you noticed.
          </p>
        </div>
      </.card>

      <.card title="Before your first real send">
        <ul class="list-disc pl-5 space-y-1">
          <li>Verify your from-address (or its domain) in Amazon SES.</li>
          <li>
            Get out of the SES sandbox — until you do, you can only mail addresses
            you've verified.
          </li>
          <li>Set up SPF, DKIM and DMARC on the sending domain.</li>
          <li>
            Fill in the project's postal address. It's on every email because
            CAN-SPAM requires it.
          </li>
          <li>Use <strong>Send test to me</strong> and read it in a real inbox.</li>
        </ul>
      </.card>

      <.card title="The law, briefly">
        <p>
          US CAN-SPAM permits cold B2B email if you include a working opt-out and
          a real postal address, and don't mislead in the headers or subject —
          all of which this app does by default.
        </p>
        <p>
          Canada (CASL) and the EU/UK (GDPR + PECR) are stricter and generally
          require consent or a defensible legitimate interest. If you're mailing
          into those, get advice rather than assuming the US rules carry over.
        </p>
      </.card>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">{@title}</h2>
        <div class="text-sm text-base-content/70 space-y-3 [&_code]:text-primary [&_code]:text-xs [&_strong]:text-base-content">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end
end
