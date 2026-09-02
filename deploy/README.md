# Deploying to the Hetzner box

The box already runs several apps on one pattern: a container per app built
from its repo's Dockerfile, env in a git-ignored `.env`, the shared
`global_postgres`, and the host Caddy terminating TLS. Cold Forge follows it,
at `/apps/cold-forge`, served as **go.affordablestartup.com** on loopback 4010.

This file is the server runbook. The email side — DNS, SES, inbound replies,
warm-up — is `../docs/pre-send-checklist.md`, and none of it depends on the
deploy, so start it first: DNS propagates slowly and SES production access is a
support ticket that takes a day or two.

## Before anything: the project name

Every app on this box keeps its compose file in a directory called `deploy`.
Compose derives its project name from that directory, so without an explicit
`name:` they all become project `deploy`, sharing one service name (`app`) and
one image tag (`deploy-app`). Running `docker compose up` in one app's directory
then **adopts and replaces another app's container**, and `docker compose build`
overwrites another app's image.

This took exteriorpro.io down and left it serving Cold Forge. `name: cold-forge`
at the top of `docker-compose.yml` is what prevents it. Any new app on this box
needs the same, and the existing ones are still colliding with each other.

## First deploy

```bash
# On the server
docker exec -it global_postgres psql -U postgres -c "CREATE DATABASE cold_forge_prod;"

# 4010 must actually be free — 4003 and 4008 are taken.
ss -ltnp | grep 127.0.0.1:40

mkdir -p /apps/cold-forge && cd /apps/cold-forge
git clone <repo-url> .
cp deploy/env.example deploy/.env   # fill it in — see the comments in the file
cd deploy && docker compose up -d --build

# Migrations are explicit, never at boot. A one-off container, NOT docker exec:
# before the first migrate the app crash-loops with no tables, and exec needs a
# stable container to enter.
docker compose run --rm app /app/bin/cold_forge eval "ColdForge.Release.migrate"
```

Then create your operator account. There is no signup route:

```bash
docker compose run --rm app /app/bin/cold_forge remote
```
```elixir
ColdForge.Accounts.register_user(%{email: "quibstar@gmail.com"})
```

Log in through the magic link at `/users/log-in`.

**Never run `priv/repo/seeds.exs` here** — it sets a known password.

Then DNS (`A`/`AAAA` for `go.affordablestartup.com` → the box), append
`deploy/Caddyfile.snippet` to `/etc/caddy/Caddyfile`, and `systemctl reload
caddy`. Caddy requests the certificate on reload, so the name has to resolve
first — failures count against Let's Encrypt rate limits.

## Updates

```bash
/apps/cold-forge/deploy/remote-deploy.sh
```

Pull, build, migrate one-off on the new image (the old container keeps serving
through the build), swap, health-check on loopback 4010.

There is no GitHub Action yet, because this repo has no remote. If you add one,
copy ExteriorPro's `.github/workflows/deploy.yml` pattern: CI-gated, SSHing in
with a dedicated key whose forced command can run only this one script — so a
leak of the secret cannot open a shell.

## After it's up

1. `https://go.affordablestartup.com` loads over TLS and bounces to log-in.
2. Upload a logo, then redeploy and check it is still there — that proves the
   volume, and a logo that vanishes takes the branding out of mail already sent.
3. Send yourself a test from a campaign email; read it on a phone.
4. Click the unsubscribe link and confirm it works. It is the one link that
   must never be broken.
5. Reply to the test and watch it appear under the project's **Replies** tab.

## Backups

The database is `global_postgres`, so it is covered by whatever already backs
that up — confirm `cold_forge_prod` is actually included rather than assuming
it. Uploads are a separate named volume and are not.

```bash
docker exec -t global_postgres pg_dump -U postgres cold_forge_prod | gzip > cold_forge-$(date +%F).sql.gz
docker run --rm -v cold_forge_uploads:/u -v "$PWD":/out alpine tar czf /out/uploads-$(date +%F).tar.gz -C /u .
```

Losing this database means losing the suppression list — which means emailing
people who asked you not to. That, rather than disk failure, is the reason to
test a restore.
