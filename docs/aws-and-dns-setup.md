# AWS account + DNS, step by step

Everything here is done in a browser — nothing in this repo needs to change.
Order matters: DNS propagates slowly and SES production access is a support
ticket, so both start before you need them.

## What's already true

Checked live, so you don't have to look it up:

| | |
|---|---|
| DNS host | **Namecheap** (`dns1/dns2.registrar-servers.com`) |
| `affordablestartup.com` | → `5.78.120.185` — the same Hetzner box |
| `go.affordablestartup.com` | **free**, nothing there |
| Apex MX | Namecheap email forwarding — **do not touch** |
| Apex SPF | `v=spf1 include:spf.efwd.registrar-servers.com ~all` — **do not touch** |
| DMARC | none anywhere |
| Region to use | `us-east-1` — matches ExteriorPro, and supports SES inbound |

Everything below goes on the `go.` subdomain. The apex keeps working exactly as
it does now: subdomains do not inherit SPF, and they get their own MX.

---

## Phase 1 — the AWS account

A **new account**, separate from ExteriorPro's. Reputation and sending pauses in
SES are per-account, so a bad cold campaign here must not be able to stop
ExteriorPro's invoices.

1. Sign out of AWS entirely, then create an account at `aws.amazon.com`.
   The root email must be unique — `quibstar+asllc@gmail.com` works; AWS accepts
   plus-addressing and it lands in the same inbox.
2. Company name: **Affordable Startup LLC**. Card and phone verification.
3. **Enable MFA on the root user immediately**, then stop using root.
4. Billing → **set a budget alert** ($5 is plenty to catch a mistake). SES is
   ~$0.10 per thousand emails; at 25/day this is cents a month.
5. Later, if you want one bill: AWS Organizations → invite this account from
   ExteriorPro's. Consolidated billing shares invoices, **not** reputation, so
   the isolation survives.

### The IAM user

IAM → Users → Create user (no console access) → attach an inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "ses:SendRawEmail",
    "Resource": "*"
  }]
}
```

Create an access key of type *Application running outside AWS*. Those two values
go in `deploy/.env`. Nothing else in this account needs a key.

---

## Phase 2 — verify the domain in SES

SES → make sure you are in **us-east-1** → Verified identities → Create identity.

- Identity type: **Domain**
- Domain: `go.affordablestartup.com`
- **Easy DKIM**, RSA 2048
- Leave "Publish to Route 53" off — DNS is at Namecheap
- Skip custom MAIL FROM for now. DKIM alignment alone satisfies DMARC; it is a
  later refinement, not a launch blocker.

SES then shows **three CNAME records**. Keep that tab open — you need it in the
next phase, and the values are generated per identity, so nobody can give them
to you in advance.

---

## Phase 3 — DNS at Namecheap

Domain List → Manage → **Advanced DNS** → Host Records.

> **The one mistake everyone makes.** Namecheap's **Host** field takes the
> subdomain part *only*. SES shows you a full hostname. Paste it whole and you
> get `…go.affordablestartup.com.affordablestartup.com`, which resolves to
> nothing and fails verification with no useful error. **Strip
> `.affordablestartup.com` off the end of every Host value below.**

| Type | Host | Value | Priority |
|---|---|---|---|
| A | `go` | `5.78.120.185` | — |
| TXT | `go` | `v=spf1 include:amazonses.com ~all` | — |
| CNAME | `<token1>._domainkey.go` | `<token1>.dkim.amazonses.com` | — |
| CNAME | `<token2>._domainkey.go` | `<token2>.dkim.amazonses.com` | — |
| CNAME | `<token3>._domainkey.go` | `<token3>.dkim.amazonses.com` | — |
| TXT | `_dmarc.go` | `v=DMARC1; p=none; rua=mailto:dmarc@affordablestartup.com` | — |

The three `<token>` values come from the SES tab. TTL: Automatic.

DKIM verification usually completes in minutes; SES will keep checking for 72
hours. Until it says **Verified**, nothing can send.

### If you want DMARC reports (optional)

Reports go to a different domain than the one publishing the record, so DMARC
requires the receiving domain to opt in. One more record:

| Type | Host | Value |
|---|---|---|
| TXT | `go.affordablestartup.com._report._dmarc` | `v=DMARC1` |

Then add `dmarc@affordablestartup.com` under Namecheap's **Email Forwarding**,
pointed at your Gmail. Skip all of this and drop the `rua=` part if you'd rather
move fast — `v=DMARC1; p=none` on its own is valid and is what bulk-sender rules
actually require.

---

## Phase 4 — production access

SES → Account dashboard → **Request production access**. Until this clears you
can only mail addresses you have verified by hand, so start it now; it usually
takes a day or two.

Answer honestly. Cold outreach is permitted on SES; hiding it is what gets
accounts closed later.

- **Mail type:** Marketing
- **Website:** `https://exteriorpro.io` (the product being sold)
- **Sending volume:** starting at 25/day, ramping toward a few hundred
- **How you build your list:** publicly listed business contact details for
  exterior contractors in West Michigan, collected manually. B2B only, no
  purchased lists, no consumer addresses.
- **How recipients unsubscribe:** one-click unsubscribe in every message
  (RFC 8058 `List-Unsubscribe` / `List-Unsubscribe-Post`) plus a link in the
  footer. Opt-outs go to a global suppression list that blocks the address
  across every campaign, immediately and permanently.
- **How you handle bounces and complaints:** SNS bounce and complaint topics
  post to an endpoint that adds the address to a global suppression list
  automatically and stops every campaign it is in. Permanent bounces and
  complaints suppress immediately; transient bounces do not.

---

## Phase 5 — inbound replies

**Do this after Phase 3 is verified and sending works.** It is the only step
that can break your existing email, so it should not be tangled up with launch.

> **Namecheap warning.** Adding any MX record may require switching **Mail
> Settings** from *Email Forwarding* to *Custom MX*, which drops the apex
> records that forward your `@affordablestartup.com` mail. If it does, re-add
> these by hand — captured live, so this is the exact set to restore:
>
> | Host | Value | Priority |
> |---|---|---|
> | `@` | `eforward1.registrar-servers.com` | 10 |
> | `@` | `eforward2.registrar-servers.com` | 10 |
> | `@` | `eforward3.registrar-servers.com` | 10 |
> | `@` | `eforward4.registrar-servers.com` | 15 |
> | `@` | `eforward5.registrar-servers.com` | 20 |
>
> Send yourself a test at your `@affordablestartup.com` address afterwards to
> confirm forwarding still works.

1. Add the inbound MX:

   | Type | Host | Value | Priority |
   |---|---|---|---|
   | MX | `go` | `inbound-smtp.us-east-1.amazonaws.com` | 10 |

2. SES → **Email receiving** → Create rule set → rule for recipient
   `go.affordablestartup.com`, action **Publish to Amazon SNS**.
3. SNS → the topic → Create subscription → protocol **HTTPS**, endpoint
   `https://go.affordablestartup.com/inbound/<INBOUND_TOKEN>` (the value from
   `deploy/.env`).
4. SNS sends a `SubscriptionConfirmation` first. **The app confirms it itself**
   — it verifies Amazon's signature on the message, then follows the
   `SubscribeURL`, which is inside the signed data. Nothing to click. The
   subscription should read *Confirmed* in the console within a second or two;
   if it still says `PendingConfirmation`, the endpoint isn't reachable or the
   token in the URL is wrong.

Verify by replying to a test send: it should appear under the project's
**Replies** tab within seconds, matched `exact`. A run of `by address` matches
means `Message-ID` isn't surviving the round trip.

---

## Phase 6 — bounces and complaints

This is the one that keeps the account alive. SES suspends senders above
roughly **5% bounces** or **0.1% complaints**, measured whether or not anyone is
watching, and cold outreach to hand-collected addresses starts well above 5%
until the list cleans itself.

The endpoint is `/feedback/:token` — a different path from replies, so the two
SNS topics cannot be subscribed to each other by accident. It uses the **same**
`INBOUND_TOKEN`.

1. SNS → Create topic, e.g. `cold-forge-feedback`.
2. SES → Verified identities → `go.affordablestartup.com` → **Notifications** →
   edit Feedback notifications. Set **Bounce** and **Complaint** to that topic.
   Leave Delivery off — it is a lot of traffic that changes nothing.
3. Check **Include original headers**.
4. SNS → the topic → Create subscription → protocol **HTTPS**, endpoint
   `https://go.affordablestartup.com/feedback/<INBOUND_TOKEN>`
5. **No confirmation step.** The app verifies the signature and confirms
   itself, same as the reply topic. Check the subscription reads *Confirmed*.

### What it does

| SES sends | Result |
|---|---|
| Bounce, `Permanent` | Suppressed as `bounced`, prospect marked, campaigns stopped |
| Bounce, `Transient` / `Undetermined` | **Nothing** — a full mailbox is not a dead address |
| Complaint | Suppressed as `complained`, campaigns stopped |
| Complaint, `not-spam` | **Nothing** — the recipient rescued it *from* spam |
| Delivery, anything else | Ignored |

Suppression is global and happens even when no prospect matches, because SES
reports bounces for addresses whose prospect has since been deleted. Redelivery
is safe: SNS delivers at least once, and every path here is idempotent.

### Test it before you trust it

SES has mailbox simulator addresses that produce each outcome without touching a
real inbox or counting against your reputation. Add them as prospects and send:

```
bounce@simulator.amazonses.com      → permanent bounce
complaint@simulator.amazonses.com   → complaint
success@simulator.amazonses.com     → clean delivery
```

After the first two, both addresses should appear on the suppression list with
reasons `bounced` and `complained`. If they don't, the subscription never
confirmed — that is the failure this step exists to catch, and catching it here
costs nothing.

### Why SNS at all

SES has no plain "POST to my URL" setting; SNS is how it delivers, and every
other option (EventBridge, Firehose) is more AWS to configure, not less. What
arrives at `/feedback/:token` is an ordinary HTTPS POST that this app parses and
acts on entirely on its own — SNS is the postman, not a processor.

Two things guard it: the secret in the URL, and Amazon's signature on the
message body. The signature is checked against a certificate fetched from
Amazon, and the URL that certificate comes from is validated first — a verifier
that fetched whatever URL the caller named would be a request-forgery hole
wearing the costume of a security check.

## Order of operations

1. Create the account, IAM user, budget alert *(Phase 1)*
2. Create the SES identity, copy the DKIM records *(Phase 2)*
3. Add DNS at Namecheap, wait for **Verified** *(Phase 3)*
4. Request production access — start it, don't wait on it *(Phase 4)*
5. Fill in `deploy/.env`, deploy, add the Caddy block *(`deploy/README.md`)*
6. Send yourself a test; click the unsubscribe link
7. Wire bounce and complaint notifications, and test with the simulator
   addresses *(Phase 6)*
8. Add inbound MX and SNS *(Phase 5)*
9. Replace the postal-address placeholder, then send for real
   *(`pre-send-checklist.md`)*
