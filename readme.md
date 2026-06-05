# Deploy Script

A production-grade Bash deploy script with automatic rollback, health checks, pre-flight validation, and Slack notifications. No external dependencies — pure Bash.

Built as part of learning DevOps fundamentals: zero-downtime deployments, rollback strategies, and operational safety.

---

## What it does

```
1. Pre-flight checks     — Docker running, image exists, disk space, env vars
2. Production gate       — requires typing 'yes' for prod deploys
3. Rollback snapshot     — saves current running version before touching anything
4. Pull new image        — docker pull from registry
5. Run DB migrations     — alembic upgrade head (with 120s timeout)
6. Start new container   — stop old, start new with docker run
7. Health check loop     — polls /health until 3 consecutive 200s or timeout
8. Auto rollback         — if health check fails and --rollback-on-fail is set
9. Notify                — Slack webhook or email on success/failure
10. Cleanup              — docker image prune
```

If anything fails at any step, the script exits immediately (`set -euo pipefail`). No half-deployed states.

---

## Files

```
deploy-script/
├── deploy.sh       # Main script (~200 lines)
└── deploy.conf     # Environment-agnostic config (registry, service name, ports)
```

Optional per-environment overrides (not committed — create locally):
```
deploy.prod.conf      # production overrides
deploy.staging.conf   # staging overrides
deploy.dev.conf       # dev overrides
```

---

## Quick start

```bash
chmod +x deploy.sh

# See all commands without executing anything
./deploy.sh --env staging --version v1.0.0 --dry-run

# Deploy to staging
./deploy.sh --env staging --version v1.0.0

# Deploy to prod with auto-rollback if health check fails
./deploy.sh --env prod --version v1.2.3 --rollback-on-fail

# Manual rollback to previous version
./deploy.sh --env prod --rollback
```

---

## Options

| Flag | Description |
|------|-------------|
| `--env ENV` | Target environment: `prod`, `staging`, `dev` (required) |
| `--version VERSION` | Image tag to deploy. Defaults to `latest` |
| `--rollback-on-fail` | Auto rollback if health check fails |
| `--rollback` | Skip deploy, restore previous version immediately |
| `--dry-run` | Print every command without executing anything |
| `--help` | Show usage |

---

## Configuration

Edit `deploy.conf` to match your setup:

```bash
# Your Docker Hub username and image name
REGISTRY="docker.io/yourname"
IMAGE_NAME="your-app"

# The running container name
SERVICE_NAME="your-app"
CONTAINER_NAME="your-app"

# Port mapping
HOST_PORT=8000
CONTAINER_PORT=8000

# Health check settings
HEALTH_ENDPOINT="http://localhost:${HOST_PORT}/health"
HEALTH_TIMEOUT=60       # seconds to wait
HEALTH_INTERVAL=3       # seconds between polls
HEALTH_CONSECUTIVE=3    # consecutive 200s required to pass

# Optional notifications
SLACK_WEBHOOK=""        # https://hooks.slack.com/services/...
NOTIFY_EMAIL=""         # ops@yourcompany.com
```

For environment-specific values, create `deploy.prod.conf` alongside `deploy.conf` — it gets sourced as an override.

---

## How rollback works

Before every deploy, the script saves the current running image tag to a snapshot file:

```bash
# Saved automatically before deploy
echo "image=docker.io/yourname/your-app:v1.1.0" > /tmp/deploy_rollback_your-app

# On failure (or manual --rollback), reads the snapshot and restores it
docker stop your-app
docker run ... docker.io/yourname/your-app:v1.1.0
```

The rollback itself runs a health check — if the previous version is also unhealthy, the script exits with code 2 and sends a critical alert.

**First deploy has no snapshot** — there's nothing to roll back to. This is expected.

---

## Health check

The health check polls `GET /health` repeatedly after starting the container:

```
attempt 1 → 000 (container still starting) — waiting
attempt 2 → 000 — waiting
attempt 3 → 200 ✓ (1/3)
attempt 4 → 200 ✓ (2/3)
attempt 5 → 200 ✓ (3/3) — PASSED
```

Three consecutive 200s are required to prevent a flapping service from passing. If the timeout (default 60s) is reached before 3 consecutive 200s, deploy is declared failed.

Your app needs a `GET /health` endpoint that returns HTTP 200 when ready. A minimal FastAPI example:

```python
@app.get("/health")
async def health():
    return {"status": "ok"}
```

---

## Dry run

Every destructive command is wrapped in a `run()` function that prints instead of executing in dry-run mode:

```bash
./deploy.sh --env prod --version v1.2.3 --dry-run
```

```
[DRY-RUN] docker pull docker.io/yourname/your-app:v1.2.3
[DRY-RUN] timeout 120 docker run --rm ... python -m alembic upgrade head
[DRY-RUN] docker stop --time 30 your-app
[DRY-RUN] docker run -d --name your-app ...
```

Always dry-run before a prod deploy.

---

## Demo run

Running against a real image with `--rollback-on-fail`:

```
[19:50:48] Config loaded: env=prod image=docker.io/nman69/deployproj:v1.0.0
══ Pre-flight checks
[19:50:49] ✓ Docker daemon is running
[19:50:50] ✓ Image exists: docker.io/nman69/deployproj:v1.0.0
[19:50:50] ✓ Disk space OK: 945GB free
  ⚠  Deploying to PRODUCTION
  Type 'yes' to continue: yes
[19:50:51] ✓ All pre-flight checks passed
══ Saving rollback snapshot
[19:50:51] ⚠ No running container found — first deploy, no snapshot needed
══ Pulling image: docker.io/nman69/deployproj:v1.0.0
[19:50:53] ✓ Image pulled
══ Starting new container
[19:52:23] ✓ Container started: deployproj-api
══ Health check: http://localhost:8000/health
[19:52:23] Waiting for 3 consecutive 200s (timeout: 60s) …
[19:52:23]   ✗ 000 — waiting …
...
[19:53:19] ✗ Health check FAILED after 60s
══ ROLLING BACK (health check failure)
```

---

## Integrating with GitHub Actions

In production you'd call this script from CI/CD rather than manually:

```yaml
- name: Deploy to staging
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
    REDIS_URL: ${{ secrets.REDIS_URL }}
  run: |
    chmod +x deploy.sh
    ./deploy.sh --env staging --version ${{ github.sha }} --rollback-on-fail
```

---

## Key concepts demonstrated

| Concept | Where |
|---------|-------|
| `set -euo pipefail` — fail fast | Top of `deploy.sh` |
| `getopts` argument parsing | `main()` while loop |
| Production safety gate | `preflight_checks()` |
| Rollback snapshot save/restore | `save_rollback_snapshot()` / `do_rollback()` |
| Health check with consecutive successes | `health_check()` |
| Dry-run mode via `run()` wrapper | Throughout |
| Exponential-style timeout | `health_check()` loop |
| Slack / email notifications | `notify()` |
| Coloured terminal output | `log()` / `success()` / `error()` |
| Sourced config with overrides | `load_config()` |

---

## Requirements

- Bash 4+
- Docker
- `curl` (for health checks and Slack notifications)
- `mail` (optional, for email notifications)

No Python, no Node, no package manager.

---

## What's next

This script covers single-server Docker deploys. Natural next steps:

- **Kubernetes + ArgoCD** — GitOps-based deploy, no SSH needed, rollback via `kubectl rollout undo`
- **Blue-green deploy** — run new version alongside old, switch traffic atomically
- **Canary deploy** — shift 10% of traffic to new version, watch error rate, then promote
- **Multi-server** — parallel deploy across N hosts with a success threshold