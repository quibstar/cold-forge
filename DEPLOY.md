# Deploying Cold Forge

One Hetzner box runs everything: the app, Postgres, and Caddy for TLS. That is
a deliberate choice — this is a single-operator tool, and anything cleverer
costs operational attention every day for a benefit that arrives at a scale
this will not reach.

The order below matters. DNS propagates slowly and SES approval is not instant,
so both are started early and used later.

---

## 1. The domain, first

Everything downstream depends on this name, and it is the one thing that is
genuinely painful to change: it appears in every tracked link, unsubscribe and
survey URL inside mail you have already sent. Those URLs outlive deploys. An
unsubscribe link that stops resolving is both a broken promise and a compliance
problem.

Use a subdomain, not the domain carrying your real business mail — cold
outreach damages sending reputation even done well, and that should land
somewhere you could abandon. Avoid `marketing.` and `track.`: the host shows up
in every link a recipient hovers, and both announce bulk mail before the email
has said anything. `go.` reads as nothing at all.

```
A    go.affordablestartup.com    <hetzner-ipv4>
AAAA go.affordablestartup.com    <hetzner-ipv6>
```

Wait for it to resolve before starting Caddy. It requests a certificate on
first boot, and failures count against Let's Encrypt rate limits.

## 2. The server

Hetzner CX22 (2 vCPU, 4 GB) is comfortable. Debian or Ubuntu.

```bash
# Not as root.
adduser deploy && usermod -aG sudo deploy

# Docker
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy

# Only 80, 443 and SSH. Postgres must never be reachable from outside —
# compose keeps it on an internal network, and this is the second lock.
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable
```

## 3. Configuration

```bash
git clone <your-remote> cold_forge && cd cold_forge
cp .env.example .env
mix phx.gen.secret            # SECRET_KEY_BASE
openssl rand -hex 32          # INBOUND_TOKEN
```

Fill in `.env`. It is gitignored; keep it that way.

## 4. Start it

```bash
docker compose up -d --build
docker compose logs -f app
```

Migrations run automatically at boot. Then create your operator account:

```bash
docker compose exec app bin/cold_forge remote
```
```elixir
ColdForge.Accounts.register_user(%{email: "you@example.com"})
```

Log in via the magic link at `/users/log-in`. **Do not run `priv/repo/seeds.exs`
in production** — it sets a known password.

---

## 5. Sending: Amazon SES

SES was chosen because it tolerates cold outreach if your bounce and complaint
rates stay low. Postmark, Resend and SendGrid prohibit it outright in their
acceptable-use policies, so a working integration there is an account waiting
to be closed.

1. **Verify the domain** — SES → Verified identities → `go.affordablestartup.com`.
   Add the three DKIM `CNAME` records it gives you.
2. **SPF** on the subdomain:
   `TXT go.affordablestartup.com` → `v=spf1 include:amazonses.com ~all`
3. **DMARC** on the *root*:
   `TXT _dmarc.affordablestartup.com` →
   `v=DMARC1; p=none; sp=none; rua=mailto:dmarc@affordablestartup.com`

   `sp=none` is the part people miss. Subdomains inherit the root's policy, so
   tightening `p` to `quarantine` later would silently start failing your
   outreach until you noticed.
4. **Request production access.** New accounts are sandboxed and can only mail
   addresses you have verified. This is a support request and takes a day or
   two — start it early.
5. **IAM**: one user, `ses:SendRawEmail`, nothing else. Those are the keys in
   `.env`.

### Warm up

A domain with no sending history that suddenly emits hundreds a day is how a
sending domain gets blocked, usually permanently.

| Week | Per day |
|---|---|
| 1 | 10–20 |
| 2 | 25–40 |
| 3 | 50–75 |
| 4+ | climb while complaints stay under 0.1% |

The campaign's daily cap enforces this — it is set to 25, which is week-two
pacing. Raise it deliberately, not because a list is large.

---

## 6. Replies: SES inbound

Without this, replies are invisible and people who have already answered keep
getting chased — the fastest way to look like a machine.

1. **MX** on the sending subdomain:
   `MX go.affordablestartup.com` → `10 inbound-smtp.<region>.amazonaws.com`
2. **SES → Email receiving → Rule set**, for recipient
   `go.affordablestartup.com`, with an SNS publish action.
3. **SNS subscription**: HTTPS, to
   `https://go.affordablestartup.com/inbound/<INBOUND_TOKEN>`

SNS sends a `SubscriptionConfirmation` first. The endpoint answers `200` to
anything it does not recognise — deliberately, so providers stop retrying mail
that will never match — so confirm the subscription from the SNS console rather
than expecting the app to do it.

Check it works by replying to a test send: the reply should appear under the
project's **Replies** tab within seconds, matched `exact`. A run of `by address`
matches means the `Message-ID` header is not surviving the round trip.

---

## 7. Before the first real send

- [ ] **Postal address** on the project is your registered one. It ships with a
      shouted placeholder on purpose; CAN-SPAM requires a real address, so a
      convincing fake is a legal problem rather than a cosmetic one.
- [ ] Callback number set, or the voicemail scripts cannot be filled in.
- [ ] Send yourself a test from a campaign email and read it on a phone.
- [ ] Click the unsubscribe link and confirm it works. It is the one link that
      must never be broken.

## Updating

```bash
git pull && docker compose up -d --build
```

Migrations run at boot. Uploaded logos live on a named volume, so they survive
rebuilds — they cannot live in `priv`, which a release stores under a versioned
path that changes with every deploy.

## Backups

`pgdata` and `uploads` are named volumes. Hetzner's snapshots cover the disk,
but a nightly logical dump is what you actually restore from:

```bash
docker compose exec -T db pg_dump -U cold_forge cold_forge | gzip > backup-$(date +%F).sql.gz
```

Losing this database means losing your suppression list — which means emailing
people who asked you not to. Treat that as the reason to test a restore, not
the disk failing.
