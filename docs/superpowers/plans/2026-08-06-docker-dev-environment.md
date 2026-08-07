# Docker Dev Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a developer clone this repo and run the app via `docker compose up`, with no local Perl install required.

**Architecture:** A repo-root `Dockerfile` builds an image from a stable Perl base, installing dependencies via `cpanm --installdeps .` against the **current, unmodified `cpanfile`** — this branch is based directly on `main`, which is still the SQLite/DBIx::Class app (the Postgres migration lives in a separate, not-yet-merged branch/PR). `docker-compose.yml` gets a single `app` service, bind-mounting the repo for hot-reload via `morbo`. There is no `postgres` service in this PR — main doesn't use Postgres. That service gets added later, when the Postgres-foundation branch rebases on top of this one and reapplies its own already-reviewed commit that adds it.

**Do not attempt to add Postgres support, a database-abstraction layer, or modify `Model::DB.pm`/`migrate.pl`/`reset_test_data.pl` to be "database-agnostic" in this plan.** That work already exists, fully reviewed, on a separate branch — duplicating or second-guessing it here creates a competing implementation that will conflict when the branches are later combined. This plan's entire scope is: containerize the app exactly as it exists on `main` today (SQLite, `create_db_schema.pl`, `reset_test_data.pl`, unchanged).

**Tech Stack:** Docker, Docker Compose, `perl:5.38-slim` base image.

## Global Constraints

- **Scope is Docker packaging only.** Do not modify any file under `lib/` for this plan. If something under `lib/` appears to need a change to make the container work, STOP and report BLOCKED/NEEDS_CONTEXT rather than making the change — that's a signal the plan's assumptions are wrong, not a green light to improvise a fix.
- This is additive, not a replacement for host-based development — the existing `cpanm --installdeps .` workflow keeps working unchanged.
- Dev server is `morbo` (hot-reload), not `hypnotoad` — matches the existing local dev workflow.
- Base this work on `main` directly. This PR is meant to land first, with the Postgres-foundation and OpenAPI branches rebasing onto it afterward — do not add anything here that anticipates or duplicates that work.
- Bind the app's port to `127.0.0.1` only, not `0.0.0.0`.
- Docker networking and container names are host-global, not scoped per git worktree — other worktrees on this machine may have their own docker-compose stacks running concurrently. Use a project name for this stack (via `docker compose -p` or a `.env`'s `COMPOSE_PROJECT_NAME`, or simply the directory name default) that won't collide, and if `docker compose up` reports a port already in use, investigate what's using it (`docker ps`) rather than silently picking a different port — report it if the fix isn't obvious.

---

## Task 1: Dockerfile + docker-compose app service

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.yml`

**Interfaces:**
- Produces: `docker compose up -d --build` brings up `app`, reachable at `http://127.0.0.1:3000`, running the same SQLite-backed app that runs via `morbo script/koha_plugin_store` today.

- [ ] **Step 1: Confirm the starting state**

Read `cpanfile` and `lib/KohaPluginStore/Model/DB.pm` in this worktree and confirm they are unchanged from `main` (SQLite DSN, `Mojo::SQLite`/`DBIx::Class::Schema` in `cpanfile`). If they look different from that, STOP and report NEEDS_CONTEXT — don't proceed on an assumption that turns out wrong.

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
FROM perl:5.38-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY cpanfile ./
RUN cpanm --installdeps --notest .

COPY . .

EXPOSE 3000

CMD ["morbo", "--listen", "http://*:3000", "script/koha_plugin_store"]
```

(No `libpq-dev` — nothing in the current `cpanfile` needs it. If `cpanm --installdeps` fails on a package needing a system library, add exactly that library, nothing preemptive.)

- [ ] **Step 3: Write docker-compose.yml**

```yaml
services:
  app:
    build: .
    volumes:
      - .:/app
    ports:
      - "127.0.0.1:3000:3000"
```

- [ ] **Step 4: Verify it works end-to-end**

Run: `docker compose up -d --build`
Expected: the `app` container starts and stays running (`docker compose ps` shows `running`, not restarting).

Run: `docker compose exec app perl lib/KohaPluginStore/Command/create_db_schema.pl`
Expected: completes without error (creates `database.db` inside the container, which appears on the host too via the bind mount — already covered by the existing `.gitignore`'s `database.*` pattern, confirm it doesn't show up in `git status`).

Run: `docker compose exec app perl lib/KohaPluginStore/Command/reset_test_data.pl`
Expected: completes without error.

Run: `curl -s http://127.0.0.1:3000/ | grep -o 'Mojolicious\|Koha'`
Expected: some output confirming the home page rendered (check what the current `main` home page actually contains — don't assume it says "Koha Plugin Store" the way a later branch's template does; verify against what's really in `templates/site/index.html.ep` on this branch).

As a hot-reload check: edit a template's visible text on the host, re-run the `curl`, confirm the change appears without restarting the container, then revert the edit.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile docker-compose.yml
git commit -m "Add Docker-based dev environment (app service + Dockerfile)"
```

---

## Task 2: Document the Docker dev flow in README

**Files:**
- Modify: `README.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Add a "Docker development" section to README.md**

Add this as a new subsection under the existing `## Backend` section, after the existing "Notes"/"Commands" bullets:

```markdown
### Docker development

No local Perl install needed:

1. `docker compose up -d --build`
2. `docker compose exec app perl lib/KohaPluginStore/Command/create_db_schema.pl` (first run only)
3. `docker compose exec app perl lib/KohaPluginStore/Command/reset_test_data.pl` (optional demo data)
4. Visit http://127.0.0.1:3000

Edits to the repo on your host are picked up automatically (`morbo` hot-reloads inside the
container) — no rebuild needed unless you change `cpanfile` or the `Dockerfile` itself.

A `koha_plugin_store.conf` (see `koha_plugin_store.conf.example`) is only needed for the
GitHub-backed plugin submission flow, not for browsing the site.
```

- [ ] **Step 2: Verify the documented steps match Task 1's actual file names/commands**

Re-read `Dockerfile` and `docker-compose.yml` as they exist in this worktree, and confirm every command/path in the new README section matches exactly. Also confirm the "only needed for GitHub-backed flow" claim about `koha_plugin_store.conf` is actually true by checking whether `lib/KohaPluginStore.pm`'s `startup()` requires a config file to boot — don't take this document's word for it.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the Docker development workflow"
```
