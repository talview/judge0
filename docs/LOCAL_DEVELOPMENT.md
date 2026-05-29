# Local Development — talview/judge0 (v1.13.1 Talview fork)

This fork backs **`compiler.talview.com`** (the new bookworm-based Judge0
instance, `p119-judge0-bookworm` in `prod-cluster`). It also previously backed
`judge0.talview.com` (`p075-judge0`) — that one still ships from upstream
`judge0/judge0:1.13.1`.

The live branch is **`release/v1.13.1-talview`**. Everything below assumes
that branch unless stated otherwise.

---

## Repo layout (Talview-specific)

| File | What we changed |
|---|---|
| `Dockerfile` | Base swapped from `judge0/buildpack-deps:buster-2019-12-28` → Talview-built bookworm compilers image. OpenSSL 1.1.1w + Ruby 2.7.8 compiled in-image so Rails 5.2 still runs. `production` is the **last** stage so `docker build .` produces a runnable image (see SRE-3138). |
| `config/initializers/resque.rb` | Honors `REDIS_DB` env so p119 (DB 1) doesn't share Resque queues with p075 (DB 0). Both pin Resque queue name to `Judge0::VERSION` = `1.13.1`. (SRE-3134) |
| `config/initializers/skip_plpgsql_enable_extension.rb` | Suppresses `enable_extension "plpgsql"` so `db:schema:load` works on Azure Flex PostgreSQL, which enforces an `azure.extensions` allow-list. (SRE-3139) |
| `db/schema.rb` | `enable_extension "plpgsql"` removed (belt-and-braces; the initializer above is the safety net if a future `db:schema:dump` regenerates it). |
| `db/languages/active.rb` | `compile_cmd` / `run_cmd` paths repointed to the new `/usr/local/<lang>-<version>/` directories baked by the bookworm compilers image. |
| `docker-entrypoint.sh` | cgroupv2 delegation setup at container start: creates `/sys/fs/cgroup/init` + `/sys/fs/cgroup/isolate`, propagates controllers via `cgroup.subtree_control`, and pre-creates `/run/isolate/locks`. Required by isolate v2.6. (SRE-3142) |
| `app/jobs/isolate_job.rb` | Drops `--cg-timing` / `--no-cg-timing` flags (removed in isolate v2); adds `-n 512` open-file cap for the sandbox; falls back to `metadata[:max-rss]` when `metadata[:cg-mem]` is missing — isolate v2 reads `memory.peak` (kernel 5.19+) which is absent on AKS kernel 5.15, so cg-mem silently goes nil. (SRE-3142 + SRE-3160) |
| `docs/LOCAL_DEVELOPMENT.md` | This file. |

---

## Image lineage

```
buildpack-deps:bookworm
        ↓
talview/judge0-compilers  (branch: master / fix/buster-archive-build)
        ↓ talview.azurecr.io/judge0-compilers:bookworm-<date>-<sha>
        ↓
talview/judge0            (branch: release/v1.13.1-talview)
        ↓ talview.azurecr.io/judge0:bookworm-<date>-<sha>-prod
        ↓
prod-cluster/helm-charts/platform/p119-judge0-bookworm.yaml
        ↓
compiler.talview.com  (3 server pods + N consumer workers in platform ns)
```

The compilers image is **upstream** of this repo. If you want to change a
compiler version, that change lives in `talview/judge0-compilers`, not here.
This repo only needs an update when:

- the consumer image is being rebuilt against a new compilers tag, or
- the Rails code or language metadata (`db/languages/active.rb`) needs to
  change.

---

## Building the consumer image

### Build defaults to `production`

After SRE-3138 the Dockerfile orders stages `base → development → production`
(production last). So:

```bash
docker build -t talview.azurecr.io/judge0:bookworm-$(date +%Y%m%d)-$(git rev-parse --short HEAD)-prod .
```

This is what you want for prod. If you want the dev sleep-shim image (for
`docker exec` poking around), use:

```bash
docker build --target development -t judge0:dev .
```

### Bump the compilers base image

When the bookworm compilers image gets rebuilt, update the **first line** of
`Dockerfile`:

```diff
-FROM talview.azurecr.io/judge0-compilers:bookworm-20260528-2285831 AS base
+FROM talview.azurecr.io/judge0-compilers:bookworm-<new-date>-<new-sha> AS base
```

…and rebuild + retag the consumer image. There are no other repo files that
reference the compilers tag.

### Push to ACR

```bash
az acr login -n talview
docker push talview.azurecr.io/judge0:bookworm-<date>-<sha>-prod
```

Then update `prod-cluster/helm-charts/platform/p119-judge0-bookworm.yaml`
`image.tag` and open a PR. ArgoCD on **EU/Platform** is **manual-sync** for
this app — once merged, ask Harish to apply.

---

## Running locally with `docker-compose.dev.yml`

```bash
cp judge0.conf.example judge0.conf   # if needed
docker compose -f docker-compose.dev.yml up --build
```

The `judge0` service uses `target: development` so the container runs
`sleep infinity`. Exec in and run the server manually:

```bash
docker compose -f docker-compose.dev.yml exec judge0 bash
# inside container:
cd /api
bundle exec rails db:create db:schema:load   # first run only
./scripts/server                              # API
./scripts/workers                             # workers (in another exec)
```

Postgres is on the `db` service (PG 16). Redis is on `redis`.

### First-run DB bootstrap on Azure Flex

When pointing the dev container at **Azure Flex PG** instead of the local
`db` service:

1. The `skip_plpgsql_enable_extension.rb` initializer makes `db:schema:load`
   skip the `CREATE EXTENSION plpgsql` call, which Azure Flex blocks via
   `azure.extensions` allow-list.
2. The DB owner must already have `CREATE` on `public` (PG 15+ removed the
   default). Run as Azure admin once:
   ```sql
   GRANT ALL ON SCHEMA public TO p119_judge0;
   ALTER SCHEMA public OWNER TO p119_judge0;
   ```
3. Then in the container: `bundle exec rails db:schema:load`.

---

## Tag / branch conventions

- **Branch:** `release/v1.13.1-talview` is the live branch. Cut feature
  branches off it (`chore/sre-NNNN-<slug>`), open PR back into
  `release/v1.13.1-talview`, never `master`. Upstream `master` has drifted —
  see [SRE-3109 plan](https://linear.app/talview/issue/SRE-3109) for context.
- **Image tag:** `bookworm-YYYYMMDD-<git-short-sha>-prod`. The `-prod` suffix
  is there so the registry view distinguishes server/runtime images from
  earlier intermediate builds.
- **Git tags:** none yet on this branch; we tag on PR-merge SHAs implicitly
  via the image tag.

---

## Resque queue isolation (REDIS_DB)

Judge0 hardcodes the Resque queue name to `Judge0::VERSION` (`1.13.1`). p075
and p119 both ship the same version string, so without isolation they would
share a queue and a p075 submission could be picked up by a p119 worker
(running the newer compilers — wrong result).

`config/initializers/resque.rb` reads `REDIS_DB` from env and passes it to
the Redis client. Helm side: `REDIS_DB` is in the ESO secrets list on
`p119-judge0-bookworm.yaml`. Set it to a non-zero integer per instance:

- `p075-judge0`: `REDIS_DB=0` (or unset; default 0)
- `p119-judge0-bookworm`: `REDIS_DB=1`

**Gotcha:** `envFrom` is snapshotted at pod creation, so updating the K8s
Secret alone won't propagate — `kubectl rollout restart` after ESO sync.

---

## Smoke-test after deploy

Pull the `X-Auth-Token` live from KeyVault / the running Secret — never
commit or hard-code it:

```bash
TOKEN=$(kubectl --context tv-prod-platform-01 -n platform get secret p119-judge0-bookworm \
  -o jsonpath='{.data.AUTHN_TOKEN}' | base64 -d)

# 1. Language list
curl -sH "X-Auth-Token: $TOKEN" https://compiler.talview.com/languages | jq 'length'

# 2. Hello-world for a key language (Go id 60 = 1.24.3 on p119)
curl -sH "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -X POST 'https://compiler.talview.com/submissions?base64_encoded=false&wait=true' \
  -d '{"source_code":"package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"ok\")}","language_id":60}' \
  | jq '.status, .stdout'
```

Expected: `{"id":3,"description":"Accepted"}` and `"ok\n"`.

For a fuller suite (14 hello-worlds across the language matrix), see
`scripts/smoke-test.sh` (TODO — track in a follow-up).

---

## cgroupv2 migration (SRE-3142 + SRE-3160)

`compiler.talview.com` now runs on the **standard platform nodepool** (cgroupv2,
AKS Ubuntu 22.04, kernel 5.15). The dedicated `cgroupv1-judge0` nodepool is
no longer required.

### What changed in the consumer image

1. **Compilers base bumped** to an isolate-v2.6 image
   (`talview.azurecr.io/judge0-compilers:bookworm-20260529-overlay-v2-3dcc6d3`).
   Upstream `judge0/isolate@ad39cc4` is cgroupv1-only; `ioi/isolate v2.6` is
   cgroupv2-only since v2.0.
2. **`docker-entrypoint.sh`** sets up cgroupv2 delegation before `cron` and
   the Rails server start:
   - Creates `/sys/fs/cgroup/init`, moves PID 1 into it, then enables
     `cpu memory pids io cpuset` controllers via `cgroup.subtree_control`.
   - Creates `/sys/fs/cgroup/isolate` and enables the same controllers there
     (isolate's `cg_root`).
   - Creates `/run/isolate/locks` (where isolate v2 takes its sandbox locks).
3. **`app/jobs/isolate_job.rb`** drops the v1-only `--cg-timing` /
   `--no-cg-timing` flags (isolate v2 always reads cg timing) and adds
   `-n 512` to widen the open-file cap (some Go/Java toolchains exceed v2's
   stricter default).
4. **Memory metric fallback** (SRE-3160): isolate v2 reads cgroupv2's
   `memory.peak`, which requires kernel ≥ 5.19. AKS Ubuntu 22.04 ships
   kernel 5.15, so `cg-mem` silently disappears from the metadata.
   `isolate_job.rb` now uses `metadata[:cg-mem] || metadata[:max-rss]` so
   `submission.memory` stays populated (max-rss comes from `getrusage`,
   always emitted). Once nodes move to a 5.19+ kernel `cg-mem` will come
   back automatically.

### Pod requirements

The container needs `privileged: true` (still — for the cgroup mount +
delegation setup the entrypoint performs). It does **not** need any
`nodeSelector` / tolerations for the old `cgroupv1-judge0` pool.

In `global-helm` 4.0.7, `securityContext.config.privileged: true` is only
honored when `securityContext.enabled: true` — bare `privileged: true` is a
silent no-op. The defaults also drop ALL caps and run as uid 10001, both
incompatible with the judge0 image (USER `judge0` = uid 1000; isolate needs
caps). Override every default explicitly. See
`prod-cluster/helm-charts/platform/p119-judge0-bookworm.yaml`.

### Overlay vs full rebuild

The current bookworm compilers tag (`overlay-v2-3dcc6d3`) is a thin overlay
on `bookworm-20260528-2285831` that rebuilds **only** the isolate layer. A
full clean rebuild is blocked on JDK 21.0.5 URL 404s
([SRE-3161](https://linear.app/talview/issue/SRE-3161)) — when that lands,
the next compilers tag drops the overlay.

The overlay also pins `num_boxes = 2147483647` in `/usr/local/etc/isolate`.
Judge0 computes `box_id = submission.id % 2147483647`; with v1's default
config `num_boxes = 1000` the sandbox-id range check fails silently on any
submission whose `id > 1000`, returning Internal Error.

---

## Linked Linear tickets

| Ticket | Subject |
|---|---|
| [SRE-3109](https://linear.app/talview/issue/SRE-3109) | parent — compile chain bookworm migration |
| [SRE-3126](https://linear.app/talview/issue/SRE-3126) | cgroupv2 isolate migration (future — eliminates dedicated cgroupv1 nodepool) |
| [SRE-3130–3137](https://linear.app/talview/project/judge0-compiler-upgrade-compilertalviewcom-4887b349ceb8) | completed compiler-upgrade work items |
| [SRE-3138](https://linear.app/talview/issue/SRE-3138) | Dockerfile dev-stage footgun — fixed by this doc's PR |
| [SRE-3139](https://linear.app/talview/issue/SRE-3139) | schema.rb plpgsql strip — fixed by sibling PR |
| [SRE-3142](https://linear.app/talview/issue/SRE-3142) | isolate v2.6 + cgroupv2 migration — done, deployed to p119 |
| [SRE-3160](https://linear.app/talview/issue/SRE-3160) | `memory: 0` regression — cg-mem→max-rss fallback for kernel 5.15 |
| [SRE-3161](https://linear.app/talview/issue/SRE-3161) | JDK 21.0.5 URL 404 — blocks clean compilers rebuild; overlay is the workaround |
| [SRE-3162](https://linear.app/talview/issue/SRE-3162) | mirror p119 changes back into p075-judge0 once stable |
