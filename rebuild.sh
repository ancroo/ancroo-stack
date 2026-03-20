#!/bin/bash
# rebuild.sh — Rebuild local build artifacts after code changes
#
# Rebuilds Docker images (backend, runner) and browser extension (web)
# from local source. Restarts affected containers automatically.
#
# Usage:
#   ./rebuild.sh              # rebuild all
#   ./rebuild.sh ab            # rebuild backend only
#   ./rebuild.sh ar aw         # rebuild runner + web
#   ./rebuild.sh --no-cache    # rebuild all without Docker cache
set -euo pipefail

# ─── Paths ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$SCRIPT_DIR"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${WORKSPACE_ROOT}/ancroo-backend"
RUNNER_DIR="${WORKSPACE_ROOT}/ancroo-runner"
WEB_DIR="${WORKSPACE_ROOT}/ancroo-web"

source "$STACK_DIR/tools/install/lib/common.sh"

# Read a value from an env file
read_env_value() { grep "^${1}=" "$2" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

# ─── Parse arguments ─────────────────────────────────────
REBUILD_BACKEND=false
REBUILD_RUNNER=false
REBUILD_WEB=false
NO_CACHE=""
EXPLICIT_TARGETS=false

for arg in "$@"; do
    case "$arg" in
        ab|backend)  REBUILD_BACKEND=true; EXPLICIT_TARGETS=true ;;
        ar|runner)   REBUILD_RUNNER=true;  EXPLICIT_TARGETS=true ;;
        aw|web)      REBUILD_WEB=true;     EXPLICIT_TARGETS=true ;;
        all)         REBUILD_BACKEND=true; REBUILD_RUNNER=true; REBUILD_WEB=true; EXPLICIT_TARGETS=true ;;
        --no-cache)  NO_CACHE="--no-cache" ;;
        *)           print_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Default: rebuild all
if [[ "$EXPLICIT_TARGETS" == "false" ]]; then
    REBUILD_BACKEND=true
    REBUILD_RUNNER=true
    REBUILD_WEB=true
fi

# ─── Pre-flight checks ──────────────────────────────────
STACK_ENV="$STACK_DIR/.env"

if [[ ! -f "$STACK_ENV" ]]; then
    print_error "Stack not installed — run install.sh first"
    exit 1
fi

COMPOSE_FILE="$(read_env_value COMPOSE_FILE "$STACK_ENV")"
FAILURES=0

# ─── Helper: rebuild a Docker service ────────────────────
rebuild_docker_service() {
    local service_name="$1"
    local project_dir="$2"
    local compose_pattern="$3"

    # Check service is in COMPOSE_FILE
    if [[ "$COMPOSE_FILE" != *"$compose_pattern"* ]]; then
        print_warning "$service_name: not enabled in stack, skipping"
        return 0
    fi

    # Check project exists
    if [[ ! -d "$project_dir" ]]; then
        print_warning "$service_name: project directory not found, skipping"
        return 0
    fi

    # Get git info
    local commit version
    commit="$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "dev")"
    version="$(git -C "$project_dir" describe --tags --always 2>/dev/null || echo "dev")"

    print_step "Building $service_name ($version @ $commit)"

    # Build
    export BUILD_COMMIT="$commit" BUILD_VERSION="$version"
    if (cd "$STACK_DIR" && docker compose build $NO_CACHE "$service_name"); then
        print_success "$service_name: image built"
    else
        print_error "$service_name: build failed"
        return 1
    fi

    # Restart
    print_info "$service_name: restarting container..."
    if (cd "$STACK_DIR" && docker compose up -d "$service_name"); then
        print_success "$service_name: container restarted"
    else
        print_error "$service_name: restart failed"
        return 1
    fi
}

# ─── Helper: rebuild browser extension ───────────────────
rebuild_web() {
    if [[ ! -d "$WEB_DIR" ]]; then
        print_warning "ancroo-web: project directory not found, skipping"
        return 0
    fi

    print_step "Building ancroo-web extension"

    if bash "$WEB_DIR/build.sh"; then
        print_success "ancroo-web: extension built at $WEB_DIR/dist/"
        print_info "Reload the extension manually in Chrome"
    else
        print_error "ancroo-web: build failed"
        return 1
    fi
}

# ─── Execute ─────────────────────────────────────────────
print_header "Ancroo — Rebuild"

if [[ "$REBUILD_BACKEND" == "true" ]]; then
    rebuild_docker_service "ancroo-backend" "$BACKEND_DIR" "ancroo-backend/module/compose" || ((FAILURES++))
fi

if [[ "$REBUILD_RUNNER" == "true" ]]; then
    rebuild_docker_service "ancroo-runner" "$RUNNER_DIR" "ancroo-runner/module/compose" || ((FAILURES++))
fi

if [[ "$REBUILD_WEB" == "true" ]]; then
    rebuild_web || ((FAILURES++))
fi

# ─── Summary ─────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
    print_success "All rebuilds completed successfully"
else
    print_error "$FAILURES rebuild(s) failed"
fi

exit "$FAILURES"
