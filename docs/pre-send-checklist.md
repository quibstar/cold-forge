# Before the first real send

None of this depends on the deploy, and two items have lead times measured in
days — start them before touching the server. Server runbook:
`../deploy/README.md`.

## 1. The domain

Use a subdomain, not the name carrying real business mail. Cold outreach damages
sending reputation even when done well, and that damage should land somewhere
you could abandon without losing your invoices.

Avoid `marketing.` and `track.`: the host shows in every link a recipient
hovers, and both announce bulk mail before the email has said anything. `go.`
reads as nothing at all.

```
A    go.affordablestartup.com    <box ipv4>
AAAA go.affordablestartup.com    <box ipv6>
```

## 2. SES

The same SES account ExteriorPro uses is fine — the identity being verified is
the sending domain, and this is a different one. The IAM user needs
`ses:SendRawEmail` and nothing else.

SES is the adapter because it tolerates cold outreach as long as bounce and
complaint rates stay low. Postmark, Resend and SendGrid prohibit it outright in
their acceptable-use policies, so a working integration there is an account
waiting to be closed.

- [ ] **Verify the domain** — SES → Verified identities → `go.affordablestartup.com`,
      then add the three DKIM `CNAME` records.
- [ ] **SPF**: `TXT go.affordablestartup.com` → `v=spf1 include:amazonses.com ~all`
- [ ] **DMARC** on the *root*: `TXT _dmarc.affordablestartup.com` →
      `v=DMARC1; p=none; sp=none; rua=mailto:dmarc@affordablestartup.com`

      `sp=none` is the part people miss. Subdomains inherit the root's policy,
      so tightening `p` to `quarantine` later would silently start failing this
      outreach until someone noticed.
- [ ] **Production access.** New accounts are sandboxed and can only mail
      verified addresses. It is a support request — start it early.

## 3. Inbound replies

Without this, replies are invisible and people who already answered keep getting
chased, which is the fastest way to look like a machine.

- [ ] **MX**: `go.affordablestartup.com` → `10 inbound-smtp.<region>.amazonaws.com`
- [ ] **SES → Email receiving → Rule set** for that recipient, with an SNS
      publish action.
- [ ] **SNS subscription**: HTTPS →
      `https://go.affordablestartup.com/inbound/<INBOUND_TOKEN>`

SNS sends a `SubscriptionConfirmation` first. The endpoint answers `200` to
anything it doesn't recognise — deliberately, so providers stop retrying mail
that will never match — so confirm the subscription from the SNS console rather
than expecting the app to do it.

Verify by replying to a test send: it should appear under the project's
**Replies** tab within seconds, matched `exact`. A run of `by address` matches
means the `Message-ID` header isn't surviving the round trip.

## 4. Warm-up

A domain with no sending history that suddenly emits hundreds a day is how a
sending domain gets blocked, usually for good.

| Week | Per day |
|---|---|
| 1 | 10–20 |
| 2 | 25–40 |
| 3 | 50–75 |
| 4+ | climb while complaints stay under 0.1% |

The campaign's daily cap enforces this. It ships at 25 — week-two pacing. Raise
it deliberately, not because a list is large.

## 5. The content

- [ ] **Postal address** on the project is the registered one for Affordable
      Startup LLC. It ships with a shouted placeholder on purpose: CAN-SPAM
      requires a real address, so a *plausible* placeholder would ship as a lie
      nobody caught.
- [ ] Callback number set, or the voicemail scripts can't be filled in.
- [ ] Read one rendered email on a phone before sending it to a stranger.
- [ ] Click the unsubscribe link yourself.
