#!/usr/bin/env bash
# deploy.sh — zero-downtime deploy with automatic rollback
#
# Usage:
#   ./deploy.sh --env prod --version v1.4.2
#   ./deploy.sh --env staging --rollback-on-fail
#   ./deploy.sh --env prod --version v1.4.2 --dry-run
#   ./deploy.sh --env prod --rollback          # manual rollback to previous
#
# What it does:
#   1. Parse + validate args
#   2. Load config for target environment
#   3. Pre-flight checks (server reachable, image exists, disk space)
#   4. Save rollback snapshot (current version)
#   5. Pull new image
#   6. Run DB migrations (with timeout)
#   7. Rolling container restart (stop old → start new)
#   8. Health check loop (consecutive 200s required)
#   9. On failure: automatic rollback if --rollback-on-fail
#  10. Notify Slack / email on success or failure

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# CONSTANTS
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Terminal colours (disabled automatically if not a TTY)
if [ -t 1 ]; then
    RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m';     RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# ══════════════════════════════════════════════════════════════════════
# LOGGING
# ══════════════════════════════════════════════════════════════════════

log()     { echo -e "${BOLD}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${RESET}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${RESET}" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${RESET}" | tee -a "$LOG_FILE" >&2; }
step()    { echo -e "\n${BLUE}══ $* ${RESET}" | tee -a "$LOG_FILE"; }

# ══════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ══════════════════════════════════════════════════════════════════════

ENV=""
VERSION=""
DRY_RUN=false
ROLLBACK_ON_FAIL=false
MANUAL_ROLLBACK=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --env ENV               Target environment: prod | staging | dev (required)
  --version VERSION       Image tag to deploy (e.g. v1.4.2 or git SHA)
                          Defaults to 'latest' if omitted
  --rollback-on-fail      Automatically roll back if health check fails
  --rollback              Roll back to the previous version (skips deploy)
  --dry-run               Print all commands without executing them
  -h, --help              Show this help message

Examples:
  $(basename "$0") --env prod --version v1.4.2 --rollback-on-fail
  $(basename "$0") --env staging
  $(basename "$0") --env prod --rollback
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)              ENV="$2";     shift 2 ;;
        --version)          VERSION="$2"; shift 2 ;;
        --rollback-on-fail) ROLLBACK_ON_FAIL=true; shift ;;
        --rollback)         MANUAL_ROLLBACK=true;  shift ;;
        --dry-run)          DRY_RUN=true;           shift ;;
        -h|--help)          usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$ENV" ]] && { error "--env is required"; usage; }
[[ "$ENV" =~ ^(prod|staging|dev)$ ]] || { error "Invalid env: $ENV. Must be prod|staging|dev"; exit 1; }

# ══════════════════════════════════════════════════════════════════════
# CONFIG LOADING
# ══════════════════════════════════════════════════════════════════════

load_config() {
    local config="${SCRIPT_DIR}/deploy.conf"
    [[ -f "$config" ]] || { error "Config not found: $config"; exit 1; }
    # shellcheck source=deploy.conf
    source "$config"

    # Environment-specific overrides
    local env_config
    env_config="${SCRIPT_DIR}/deploy.${ENV}.conf"
    [[ -f "$env_config" ]] && source "$env_config"

    # Default version to 'latest' if not specified
    VERSION="${VERSION:-latest}"

    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
    log "Config loaded: env=${ENV} image=${FULL_IMAGE}"
}

# ══════════════════════════════════════════════════════════════════════
# DRY-RUN WRAPPER
# ══════════════════════════════════════════════════════════════════════

# Wrap every destructive command with run() so dry-run mode prints
# but doesn't execute.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}  [DRY-RUN] $*${RESET}" | tee -a "$LOG_FILE"
    else
        log "  $ $*"
        eval "$@"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════════

preflight_checks() {
    step "Pre-flight checks"

    # 1. Docker daemon running
    docker info > /dev/null 2>&1 || { error "Docker daemon is not running"; exit 1; }
    success "Docker daemon is running"

    # 2. Image exists in registry (skip for 'latest' — assume it's there)
    if [[ "$VERSION" != "latest" ]]; then
        if docker manifest inspect "$FULL_IMAGE" > /dev/null 2>&1; then
            success "Image exists: $FULL_IMAGE"
        else
            error "Image not found in registry: $FULL_IMAGE"
            exit 1
        fi
    fi

    # 3. Disk space — require at least 2GB free
    local free_gb
    free_gb=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    if (( free_gb < 2 )); then
        error "Insufficient disk space: ${free_gb}GB free (need 2GB)"
        exit 1
    fi
    success "Disk space OK: ${free_gb}GB free"

    # 4. Required env vars present
    for var in DATABASE_URL REDIS_URL; do
        if [[ -z "${!var:-}" ]]; then
            warn "Environment variable $var is not set"
        fi
    done

    # 5. Production safety gate — require explicit confirmation
    if [[ "$ENV" == "prod" && "$DRY_RUN" == false ]]; then
        echo -e "\n${RED}${BOLD}  ⚠  Deploying to PRODUCTION${RESET}"
        echo -e "  Image: ${FULL_IMAGE}\n"
        read -rp "  Type 'yes' to continue: " confirm
        [[ "$confirm" == "yes" ]] || { log "Deployment cancelled by user."; exit 0; }
    fi

    success "All pre-flight checks passed"
}

# ══════════════════════════════════════════════════════════════════════
# ROLLBACK SNAPSHOT
# ══════════════════════════════════════════════════════════════════════

save_rollback_snapshot() {
    step "Saving rollback snapshot"

    local current_image
    current_image=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")

    if [[ -n "$current_image" ]]; then
        echo "image=${current_image}" > "$ROLLBACK_FILE"
        echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S')" >> "$ROLLBACK_FILE"
        success "Snapshot saved: $current_image → $ROLLBACK_FILE"
    else
        warn "No running container found — first deploy, no snapshot needed"
    fi
}

load_rollback_snapshot() {
    [[ -f "$ROLLBACK_FILE" ]] || { error "No rollback snapshot found at $ROLLBACK_FILE"; exit 1; }
    # shellcheck source=/dev/null
    source "$ROLLBACK_FILE"
    echo "$image"
}

# ══════════════════════════════════════════════════════════════════════
# DEPLOY STEPS
# ══════════════════════════════════════════════════════════════════════

pull_image() {
    step "Pulling image: $FULL_IMAGE"
    run "docker pull ${FULL_IMAGE}"
    success "Image pulled"
}

run_migrations() {
    step "Running DB migrations"
    # Run migrations in a one-shot container with a 120s timeout.
    # The migrate container shares the same env as the app.
    run "timeout 120 docker run --rm \
        --network host \
        -e DATABASE_URL=${DATABASE_URL:-} \
        ${FULL_IMAGE} \
        python -m alembic upgrade head"
    success "Migrations complete"
}

start_new_container() {
    step "Starting new container"

    # Stop and remove the old container (graceful 30s SIGTERM, then SIGKILL)
    if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
        log "Stopping existing container: $CONTAINER_NAME"
        run "docker stop --time 30 ${CONTAINER_NAME}"
        run "docker rm ${CONTAINER_NAME}"
    fi

    run "docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        -p ${HOST_PORT}:${CONTAINER_PORT} \
        -e DATABASE_URL=${DATABASE_URL:-} \
        -e REDIS_URL=${REDIS_URL:-} \
        ${FULL_IMAGE}"

    success "Container started: $CONTAINER_NAME"
}

# ══════════════════════════════════════════════════════════════════════
# HEALTH CHECK
# ══════════════════════════════════════════════════════════════════════

health_check() {
    step "Health check: $HEALTH_ENDPOINT"

    local elapsed=0
    local consecutive=0

    log "Waiting for ${HEALTH_CONSECUTIVE} consecutive 200s (timeout: ${HEALTH_TIMEOUT}s) …"

    while (( elapsed < HEALTH_TIMEOUT )); do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    --connect-timeout 3 --max-time 5 \
                    "$HEALTH_ENDPOINT" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            (( consecutive++ ))
            log "  ✓ ${http_code} (${consecutive}/${HEALTH_CONSECUTIVE})"
            if (( consecutive >= HEALTH_CONSECUTIVE )); then
                success "Health check passed after ${elapsed}s"
                return 0
            fi
        else
            if (( consecutive > 0 )); then
                warn "  ✗ ${http_code} — resetting consecutive counter"
            else
                log "  ✗ ${http_code} — waiting …"
            fi
            consecutive=0
        fi

        sleep "$HEALTH_INTERVAL"
        (( elapsed += HEALTH_INTERVAL ))
    done

    error "Health check FAILED after ${HEALTH_TIMEOUT}s"
    return 1
}

# ══════════════════════════════════════════════════════════════════════
# ROLLBACK
# ══════════════════════════════════════════════════════════════════════

do_rollback() {
    local reason="${1:-manual}"
    step "ROLLING BACK ($reason)"

    local prev_image
    prev_image=$(load_rollback_snapshot)
    log "Rolling back to: $prev_image"

    # Stop broken container
    if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
        run "docker stop --time 10 ${CONTAINER_NAME}"
        run "docker rm ${CONTAINER_NAME}"
    fi

    # Start previous image
    run "docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        -p ${HOST_PORT}:${CONTAINER_PORT} \
        -e DATABASE_URL=${DATABASE_URL:-} \
        -e REDIS_URL=${REDIS_URL:-} \
        ${prev_image}"

    # Verify the rollback itself is healthy
    if health_check; then
        success "Rollback successful — running $prev_image"
        notify "⚠️ Rollback completed" "Rolled back to ${prev_image} after ${reason}"
    else
        error "Rollback health check FAILED. Manual intervention required."
        notify "🚨 CRITICAL: rollback failed" "Both ${FULL_IMAGE} and ${prev_image} unhealthy on ${ENV}"
        exit 2
    fi
}

# ══════════════════════════════════════════════════════════════════════
# NOTIFICATIONS
# ══════════════════════════════════════════════════════════════════════

notify() {
    local title="$1"
    local message="$2"

    # Slack
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"*${title}*\n${message}\nenv: \`${ENV}\`\"}" \
            > /dev/null 2>&1 || warn "Slack notification failed"
    fi

    # Email (requires sendmail or mailx)
    if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &> /dev/null; then
        echo "$message" | mail -s "$title [${ENV}]" "$NOTIFY_EMAIL" \
            2>/dev/null || warn "Email notification failed"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# CLEANUP
# ══════════════════════════════════════════════════════════════════════

cleanup_old_images() {
    step "Cleaning up dangling images"
    run "docker image prune -f"
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════

main() {
    echo "" | tee -a "$LOG_FILE"
    log "════════════════════════════════════════════════"
    log " Deploy started: env=${ENV} version=${VERSION}"
    log " Timestamp: ${TIMESTAMP}"
    log " DRY_RUN: ${DRY_RUN} | ROLLBACK_ON_FAIL: ${ROLLBACK_ON_FAIL}"
    log "════════════════════════════════════════════════"

    load_config

    # Manual rollback path — skip the full deploy
    if [[ "$MANUAL_ROLLBACK" == true ]]; then
        do_rollback "manual"
        exit 0
    fi

    preflight_checks
    save_rollback_snapshot
    pull_image
   # run_migrations
    start_new_container

    # Health check — if it fails, optionally roll back
    if ! health_check; then
        if [[ "$ROLLBACK_ON_FAIL" == true ]]; then
            do_rollback "health check failure"
            exit 1
        else
            error "Deploy failed. Run with --rollback-on-fail or manually rollback with --rollback"
            notify "❌ Deploy FAILED" "Health check failed for ${FULL_IMAGE} on ${ENV}"
            exit 1
        fi
    fi

    cleanup_old_images

    success "════════════════════════════════════════════════"
    success " Deploy complete: ${FULL_IMAGE} → ${ENV}"
    success "════════════════════════════════════════════════"
    notify "✅ Deploy successful" "${FULL_IMAGE} deployed to ${ENV}"
}

main "$@"
