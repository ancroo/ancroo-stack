#!/bin/bash
# ancroo-stack — Guided Installer
#
# Installs the full AI stack in one run:
#   Base:       PostgreSQL, Ollama, Open WebUI, Homepage, Adminer, n8n, BookStack
#   STT:        Speaches or Whisper-ROCm (selectable)
#   Optional:   Ancroo Backend, Runner, Browser Extension (auto-detected or cloned)
#
# Interactive by default. Non-interactive via environment variables:
#   ANCROO_GPU_MODE        — nvidia | rocm | cpu (default: interactive prompt)
#   ANCROO_TIMEZONE        — timezone string (default: auto-detect)
#   ANCROO_OLLAMA_MODEL    — model name to pull, "none" or empty = skip
#   ANCROO_STT_ENGINE      — "speaches" | "whisper-rocm" (default: auto based on GPU)
#   ANCROO_NONINTERACTIVE  — set to skip all prompts
#   ANCROO_FORCE_REINSTALL — set to "1" to overwrite existing .env
#
# Usage:
#   bash install.sh                                          # interactive
#   bash install.sh --dev                                    # build from source
#   ANCROO_GPU_MODE=rocm ANCROO_NONINTERACTIVE=1 bash install.sh  # non-interactive
set -euo pipefail

# ─── Setup ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${WORKSPACE_ROOT}/ancroo-backend"
RUNNER_DIR="${WORKSPACE_ROOT}/ancroo-runner"
WEB_DIR="${WORKSPACE_ROOT}/ancroo-web"
META_DIR="${WORKSPACE_ROOT}/ancroo"

source "$SCRIPT_DIR/tools/install/lib/common.sh"
source "$SCRIPT_DIR/tools/install/lib/validation.sh"
source "$SCRIPT_DIR/tools/install/lib/env-generator.sh"
source "$SCRIPT_DIR/tools/install/lib/homepage.sh"

cd "$PROJECT_ROOT"

# Parse flags
DEV_MODE=false
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=true ;;
    esac
done

# ─────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────
print_header "Ancroo Stack — Installer"

run_preflight_checks

# Check for existing installation
EXISTING_INSTALL=false
if ! check_existing_installation; then
    EXISTING_INSTALL=true
fi

if ! command -v git &>/dev/null; then
    print_warning "git is not installed — some features may not work"
fi
echo ""

# ─────────────────────────────────────────────────────────
# CONFIGURATION WIZARD
# ─────────────────────────────────────────────────────────
print_header "Configuration"

# --- GPU mode ---
if [[ -n "${ANCROO_GPU_MODE:-}" ]]; then
    case "$ANCROO_GPU_MODE" in
        nvidia) WIZARD_GPU_MODE="nvidia" ;;
        rocm)   WIZARD_GPU_MODE="rocm" ;;
        *)      WIZARD_GPU_MODE="cpu" ;;
    esac
elif $EXISTING_INSTALL; then
    WIZARD_GPU_MODE=$(grep "^GPU_MODE=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "cpu")
else
    echo "  GPU acceleration for Ollama:"
    echo "    1) CPU only (no GPU)"
    echo "    2) NVIDIA (CUDA)"
    echo "    3) AMD (ROCm)"
    echo ""
    echo -ne "  Selection [1-3]: "
    read -r gpu_choice_input
    case "$gpu_choice_input" in
        2) WIZARD_GPU_MODE="nvidia" ;;
        3) WIZARD_GPU_MODE="rocm" ;;
        *)  WIZARD_GPU_MODE="cpu" ;;
    esac
fi
print_success "GPU: ${WIZARD_GPU_MODE}"

# Derive workflow backends from GPU mode
case "$WIZARD_GPU_MODE" in
    nvidia) WIZARD_BACKENDS="cuda" ;;
    rocm)   WIZARD_BACKENDS="rocm" ;;
    *)      WIZARD_BACKENDS="cpu" ;;
esac

# --- Ollama model ---
if [[ -n "${ANCROO_OLLAMA_MODEL:-}" ]]; then
    OLLAMA_PULL_MODEL="$ANCROO_OLLAMA_MODEL"
    [[ "$OLLAMA_PULL_MODEL" == "none" ]] && OLLAMA_PULL_MODEL=""
elif [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
    OLLAMA_PULL_MODEL=""
else
    echo ""
    print_step "Ollama model"
    echo ""
    echo "  Download an LLM during installation?"
    echo ""
    echo "    1) Mistral 7B        — fast general-purpose        (~4.1 GB)"
    echo "    2) Llama 3.1 8B      — versatile, multilingual     (~4.7 GB)"
    echo "    3) Gemma 2 2B        — lightweight, fast            (~1.6 GB)"
    echo "    4) Phi-3 Mini 3.8B   — compact, efficient           (~2.3 GB)"
    echo ""
    echo -ne "  Selection [1-4, Enter=none]: "
    read -r ollama_model_choice
    OLLAMA_PULL_MODEL=""
    case "$ollama_model_choice" in
        1) OLLAMA_PULL_MODEL="mistral" ;;
        2) OLLAMA_PULL_MODEL="llama3.1" ;;
        3) OLLAMA_PULL_MODEL="gemma2:2b" ;;
        4) OLLAMA_PULL_MODEL="phi3:mini" ;;
    esac
fi
if [[ -n "${OLLAMA_PULL_MODEL:-}" ]]; then
    print_success "Ollama model: ${OLLAMA_PULL_MODEL}"
else
    print_info "Ollama model: none (can be pulled later via Open WebUI)"
fi

# --- STT engine selection ---
if [[ -n "${ANCROO_STT_ENGINE:-}" ]]; then
    STT_ENGINE="$ANCROO_STT_ENGINE"
elif [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
    if [[ "$WIZARD_GPU_MODE" == "rocm" ]]; then
        STT_ENGINE="whisper-rocm"
    else
        STT_ENGINE="speaches"
    fi
else
    echo ""
    print_step "STT engine (Speech-to-Text)"
    echo ""
    echo "    1) Speaches         — multi-model, CPU or GPU (CUDA)      (port 8100)"
    if [[ "$WIZARD_GPU_MODE" == "rocm" ]]; then
        echo "    2) Whisper ROCm     — AMD GPU-accelerated                 (port 8002)"
        echo ""
        echo -ne "  Selection [1-2, default=2]: "
    else
        echo ""
        echo -ne "  Selection [1, default=1]: "
    fi
    read -r _stt_choice
    case "${_stt_choice:-}" in
        2)
            if [[ "$WIZARD_GPU_MODE" == "rocm" ]]; then
                STT_ENGINE="whisper-rocm"
            else
                STT_ENGINE="speaches"
            fi
            ;;
        *) STT_ENGINE="speaches" ;;
    esac
fi
print_success "STT: ${STT_ENGINE}"

# --- Admin email ---
if [[ -n "${ANCROO_ADMIN_EMAIL:-}" ]]; then
    WIZARD_ADMIN_EMAIL="$ANCROO_ADMIN_EMAIL"
elif $EXISTING_INSTALL; then
    WIZARD_ADMIN_EMAIL=$(grep "^ANCROO_ADMIN_EMAIL=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    if [[ -z "$WIZARD_ADMIN_EMAIL" ]]; then
        # Fall back to existing BookStack email if migrating
        WIZARD_ADMIN_EMAIL=$(grep "^BOOKSTACK_ADMIN_EMAIL=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    fi
elif [[ -z "${ANCROO_NONINTERACTIVE:-}" ]]; then
    echo ""
    print_step "Admin email"
    echo ""
    echo "  Used for n8n, BookStack, and SSL certificates."
    echo ""
    echo -ne "  Email address: "
    read -r _admin_email_input
    WIZARD_ADMIN_EMAIL="${_admin_email_input:-}"
fi

if [[ -z "${WIZARD_ADMIN_EMAIL:-}" ]]; then
    WIZARD_ADMIN_EMAIL="admin@ancroo.local"
    print_info "Admin email: ${WIZARD_ADMIN_EMAIL} (default)"
else
    print_success "Admin email: ${WIZARD_ADMIN_EMAIL}"
fi

# Export for env-generator and n8n-provision
export ANCROO_ADMIN_EMAIL="$WIZARD_ADMIN_EMAIL"

# --- Ancroo projects (auto-detect or offer to clone) ---
ENABLE_BACKEND=false
ENABLE_RUNNER=false
ENABLE_EXTENSION=false

# In non-interactive mode, ANCROO_CLONE_PROJECTS=1 enables auto-cloning (for optional projects)
_should_clone() {
    [[ -n "${ANCROO_CLONE_PROJECTS:-}" ]] && [[ "$ANCROO_CLONE_PROJECTS" == "1" ]] && command -v git &>/dev/null
}

# Backend and Runner are required parts of the stack (separate repos for licensing)
if [[ -d "$BACKEND_DIR" ]]; then
    ENABLE_BACKEND=true
    print_success "Ancroo Backend: found at ${BACKEND_DIR}"
else
    print_step "Cloning ancroo-backend..."
    if git clone https://github.com/ancroo/ancroo-backend.git "$BACKEND_DIR" 2>/dev/null; then
        ENABLE_BACKEND=true
        print_success "Ancroo Backend cloned"
    else
        print_error "Failed to clone ancroo-backend — backend is required"
        print_info "Install git or clone manually: git clone https://github.com/ancroo/ancroo-backend.git ${BACKEND_DIR}"
        exit 1
    fi
fi

if [[ -d "$RUNNER_DIR" ]]; then
    ENABLE_RUNNER=true
    print_success "Ancroo Runner: found at ${RUNNER_DIR}"
else
    print_step "Cloning ancroo-runner..."
    if git clone https://github.com/ancroo/ancroo-runner.git "$RUNNER_DIR" 2>/dev/null; then
        ENABLE_RUNNER=true
        print_success "Ancroo Runner cloned"
    else
        print_error "Failed to clone ancroo-runner — runner is required"
        print_info "Install git or clone manually: git clone https://github.com/ancroo/ancroo-runner.git ${RUNNER_DIR}"
        exit 1
    fi
fi

if [[ -d "$META_DIR" ]]; then
    print_success "Ancroo Meta: found at ${META_DIR}"
else
    print_step "Cloning ancroo (example workflows)..."
    if git clone https://github.com/ancroo/ancroo.git "$META_DIR" 2>/dev/null; then
        print_success "Ancroo Meta cloned (example workflows available)"
    else
        print_warning "Failed to clone ancroo — example workflows won't be available"
        print_info "Clone manually: git clone https://github.com/ancroo/ancroo.git ${META_DIR}"
    fi
fi

if [[ -d "$WEB_DIR" ]]; then
    ENABLE_EXTENSION=true
    print_success "Ancroo Extension: found at ${WEB_DIR}"
elif [[ -z "${ANCROO_NONINTERACTIVE:-}" ]] && command -v git &>/dev/null; then
    if confirm "Clone Ancroo Web Extension (browser extension)?" "n"; then
        print_step "Cloning ancroo-web..."
        if git clone https://github.com/ancroo/ancroo-web.git "$WEB_DIR" 2>/dev/null; then
            ENABLE_EXTENSION=true
            print_success "Ancroo Extension cloned"
        else
            print_warning "Failed to clone ancroo-web — skipping"
        fi
    fi
elif _should_clone; then
    print_step "Cloning ancroo-web..."
    if git clone https://github.com/ancroo/ancroo-web.git "$WEB_DIR" 2>/dev/null; then
        ENABLE_EXTENSION=true
        print_success "Ancroo Extension cloned"
    else
        print_warning "Failed to clone ancroo-web — skipping"
    fi
else
    print_info "Ancroo Extension: not found (${WEB_DIR}) — skipping"
fi

# ─── Port conflict check ─────────────────────────────────
declare -A PORT_CHECK_MAP
PORT_CHECK_MAP[80]="Homepage"
PORT_CHECK_MAP[8080]="Open WebUI"
PORT_CHECK_MAP[11434]="Ollama"
PORT_CHECK_MAP[8081]="Adminer"
PORT_CHECK_MAP[5678]="n8n"
PORT_CHECK_MAP[8875]="BookStack"

if [[ "$STT_ENGINE" == "speaches" ]]; then
    PORT_CHECK_MAP[8100]="Speaches"
elif [[ "$STT_ENGINE" == "whisper-rocm" ]]; then
    PORT_CHECK_MAP[8002]="Whisper ROCm"
fi

if $ENABLE_BACKEND; then
    PORT_CHECK_MAP[8900]="Ancroo Backend"
fi
if $ENABLE_RUNNER; then
    PORT_CHECK_MAP[8510]="Ancroo Runner"
fi

blocked_ports=()
for port in "${!PORT_CHECK_MAP[@]}"; do
    if ! check_port_available "$port"; then
        blocked_ports+=("$port (${PORT_CHECK_MAP[$port]})")
    fi
done

if [[ ${#blocked_ports[@]} -gt 0 ]]; then
    echo ""
    print_warning "The following ports are already in use:"
    for entry in "${blocked_ports[@]}"; do
        echo -e "    ${YELLOW}→${NC} Port $entry"
    done
    echo ""
    print_info "An existing installation or service may be blocking these ports."
    if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
        print_info "Non-interactive mode: continuing despite port conflicts"
    elif ! confirm "Continue anyway?" "n"; then
        exit 0
    fi
fi

# ─── Pre-flight summary ──────────────────────────────────
echo ""
echo -e "  ${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}  Installation plan${NC}"
echo -e "  ${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Access:        http://IP:port (no TLS)"
echo "  GPU:           ${WIZARD_GPU_MODE}"
echo "  STT:           ${STT_ENGINE}"
echo "  Services:      PostgreSQL, Ollama, Open WebUI, Homepage, Adminer, n8n, BookStack"
echo "  Ollama model:  ${OLLAMA_PULL_MODEL:-none}"
$ENABLE_BACKEND && echo "  Ancroo:        backend" || true
$ENABLE_RUNNER && echo "  Runner:        ancroo-runner" || true
$ENABLE_EXTENSION && echo "  Extension:     browser extension" || true
echo ""
if [[ -z "${ANCROO_NONINTERACTIVE:-}" ]]; then
    echo -e "  ${YELLOW}Press Enter to start, Ctrl+C to cancel.${NC}"
    read -r
fi

if $DEV_MODE; then
    print_info "Dev mode (--dev): will build backend, runner, and extension from local source"
fi

# ─────────────────────────────────────────────────────────
# BASE INSTALLATION
# ─────────────────────────────────────────────────────────
if $EXISTING_INSTALL; then
    print_header "Base Installation — Existing"
    print_info "Existing .env found — using current configuration"
    print_info "To re-install, set ANCROO_FORCE_REINSTALL=1"

    # Sync GPU mode if user selected a different one
    _existing_gpu=$(grep "^GPU_MODE=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "cpu")
    if [[ "$WIZARD_GPU_MODE" != "$_existing_gpu" ]]; then
        print_warning "GPU mode mismatch: .env has '$_existing_gpu', selected '$WIZARD_GPU_MODE'"
        print_step "Switching GPU mode..."
        bash "$PROJECT_ROOT/stack.sh" gpu "$WIZARD_GPU_MODE"
    fi

    # Ensure base services are running (required for backend/runner depends_on)
    print_step "Ensuring base services are running..."
    docker compose up -d
    _base_wait=0
    while [[ $_base_wait -lt 60 ]]; do
        _all_up=true
        for _ctr in postgres n8n; do
            if ! docker ps --format '{{.Names}}' | grep -q "^${_ctr}$"; then
                _all_up=false
                break
            fi
        done
        $_all_up && break
        sleep 2
        _base_wait=$((_base_wait + 2))
    done
    if $_all_up; then
        print_success "Base services running"
    else
        print_error "Base services failed to start — backend/runner require postgres and n8n"
        print_info "Check: docker compose logs"
        exit 1
    fi

    # Ensure n8n database exists
    n8n_db="${N8N_DB:-ancroo_n8n}"
    if docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
        if ! docker exec postgres psql -U "${POSTGRES_USER:-ancroo}" -lqt 2>/dev/null | grep -qw "$n8n_db"; then
            docker exec postgres psql -U "${POSTGRES_USER:-ancroo}" -c "CREATE DATABASE \"${n8n_db}\";" 2>/dev/null || true
        fi
    fi

    # Ensure n8n API key exists
    _existing_n8n_key=$(grep "^ANCROO_N8N_API_KEY=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    if [[ -z "$_existing_n8n_key" ]] || [[ "$_existing_n8n_key" == CHANGE_ME* ]]; then
        print_step "Provisioning n8n API key..."
        bash "$PROJECT_ROOT/tools/install/lib/n8n-provision.sh" "$PROJECT_ROOT"
    fi
else
    print_header "Base Installation"

    # Timezone
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Berlin")
    timezone="${ANCROO_TIMEZONE:-$current_tz}"
    print_info "Timezone: $timezone"

    # Generate .env
    print_step "Generating configuration"
    export ANCROO_GPU_MODE="$WIZARD_GPU_MODE"
    create_base_env "$timezone" "$WIZARD_GPU_MODE" "$STT_ENGINE"

    # Create directories
    print_step "Creating directories"
    if [[ -d data ]] && [[ ! -w data ]]; then
        sudo chown "$(id -u):$(id -g)" data
    fi
    mkdir -p data/{ollama,open-webui,postgresql,homepage,n8n,bookstack,bookstack-db}

    # STT data directory
    if [[ "$STT_ENGINE" == "speaches" ]]; then
        mkdir -p data/speaches
    elif [[ "$STT_ENGINE" == "whisper-rocm" ]]; then
        mkdir -p data/whisper-rocm
    fi

    mkdir -p logs
    print_success "Data directories created"

    # Homepage configuration
    print_step "Configuring Homepage dashboard"
    setup_homepage

    # Password summary
    create_password_summary

    # Start base services
    print_step "Starting Docker containers"
    docker compose up -d

    echo ""
    print_info "Waiting for services to start..."
    failed_count=0
    max_wait=60
    waited=0
    while [[ $waited -lt $max_wait ]]; do
        all_running=true
        for container in postgres ollama open-webui homepage adminer n8n bookstack bookstack-db; do
            if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                all_running=false
                break
            fi
        done
        if $all_running; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    for container in postgres ollama open-webui homepage adminer n8n bookstack bookstack-db; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_success "$container running"
        else
            print_error "$container failed to start"
            failed_count=$((failed_count + 1))
        fi
    done

    # Ensure n8n database exists (init script only runs on first PG start)
    n8n_db="${N8N_DB:-ancroo_n8n}"
    if ! docker exec postgres psql -U "${POSTGRES_USER:-ancroo}" -lqt 2>/dev/null | grep -qw "$n8n_db"; then
        docker exec postgres psql -U "${POSTGRES_USER:-ancroo}" -c "CREATE DATABASE \"${n8n_db}\";" 2>/dev/null || true
    fi

    # Restart homepage to ensure config is loaded on first install
    docker restart homepage >/dev/null 2>&1 || true

    if [[ $failed_count -gt 0 ]]; then
        print_error "Base installation had failures"
        print_info "Check: docker compose logs"
        exit 1
    fi

    # ─── n8n API Key Provisioning ─────────────────────────
    print_step "Provisioning n8n API key..."
    bash "$PROJECT_ROOT/tools/install/lib/n8n-provision.sh" "$PROJECT_ROOT"
fi

# ─────────────────────────────────────────────────────────
# OLLAMA MODEL (optional)
# ─────────────────────────────────────────────────────────
ollama_model="${OLLAMA_PULL_MODEL:-}"
ollama_model_pulled="n"

if [[ -n "$ollama_model" ]]; then
    print_step "Ollama model: ${ollama_model}"
    print_info "Waiting for Ollama API..."
    ollama_ready="n"
    for _i in $(seq 1 30); do
        if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
            ollama_ready="y"
            break
        fi
        sleep 2
    done

    if [[ "$ollama_ready" == "y" ]]; then
        if docker exec ollama ollama list 2>/dev/null | grep -q "^${ollama_model}"; then
            print_success "Model ${ollama_model} already installed"
            ollama_model_pulled="y"
        else
            print_info "Downloading ${ollama_model} — this may take a few minutes..."
            if docker exec ollama ollama pull "$ollama_model"; then
                print_success "Model ${ollama_model} ready"
                ollama_model_pulled="y"
            else
                print_warning "Model pull failed — you can pull it later via Open WebUI"
            fi
        fi
    else
        print_warning "Ollama not ready after 60s — you can pull the model later via Open WebUI"
    fi
fi

# ─────────────────────────────────────────────────────────
# ANCROO BACKEND
# ─────────────────────────────────────────────────────────
if $ENABLE_BACKEND; then
    print_header "Ancroo Backend"

    export ANCROO_INSTALL_OVERWRITE="y"
    export ANCROO_ENABLE_NOW="y"

    # Pass n8n API key to Ancroo setup
    N8N_KEY_FROM_ENV=$(grep "^ANCROO_N8N_API_KEY=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    if [[ -n "$N8N_KEY_FROM_ENV" ]]; then
        export ANCROO_N8N_API_KEY_INPUT="$N8N_KEY_FROM_ENV"
    fi

    # Pass selected Ollama model
    if [[ -n "${OLLAMA_PULL_MODEL:-}" ]]; then
        export ANCROO_OLLAMA_MODEL_INPUT="$OLLAMA_PULL_MODEL"
    fi

    # Pass selected workflow backends
    export ANCROO_BACKENDS_INPUT="$WIZARD_BACKENDS"

    # Set workflows directory (points to ancroo meta-repo's example workflows)
    _current_workflows_dir=$(grep "^ANCROO_WORKFLOWS_DIR=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    if [[ -z "$_current_workflows_dir" ]]; then
        if [[ -d "$META_DIR/workflows" ]]; then
            update_env_var "ANCROO_WORKFLOWS_DIR" "../ancroo/workflows" "$PROJECT_ROOT/.env"
        fi
    fi

    if $DEV_MODE; then
        export ANCROO_LOCAL_BUILD="y"
        print_step "Dev mode: building ancroo-backend image from local source..."
        docker build \
            -t ghcr.io/ancroo/ancroo-backend:latest \
            --build-arg BUILD_COMMIT="$(cd "$BACKEND_DIR" && git rev-parse --short HEAD 2>/dev/null || echo dev)" \
            --build-arg BUILD_VERSION=dev \
            "$BACKEND_DIR"
        print_success "ancroo-backend image built from local source"
    else
        BACKEND_IMAGE="ghcr.io/ancroo/ancroo-backend:latest"
        print_step "Pulling backend image: ${BACKEND_IMAGE}"
        if docker pull "$BACKEND_IMAGE"; then
            print_success "Backend image pulled"
        else
            echo ""
            print_error "Could not pull ${BACKEND_IMAGE}"
            print_info "If the image is private, authenticate first:"
            print_info "  echo \$GHCR_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_error "Non-interactive mode: cannot continue without backend image"
                exit 1
            elif ! confirm "Continue without the backend image? (not recommended)" "n"; then
                print_info "Installation aborted — resolve the issue above and try again"
                exit 1
            fi
        fi
    fi

    bash "$BACKEND_DIR/install-stack.sh" "$PROJECT_ROOT"
    unset ANCROO_INSTALL_OVERWRITE ANCROO_ENABLE_NOW ANCROO_N8N_API_KEY_INPUT ANCROO_OLLAMA_MODEL_INPUT ANCROO_BACKENDS_INPUT
    $DEV_MODE && unset ANCROO_LOCAL_BUILD || true
fi

# ─────────────────────────────────────────────────────────
# ANCROO RUNNER
# ─────────────────────────────────────────────────────────
if $ENABLE_RUNNER; then
    print_header "Ancroo Runner"

    if $DEV_MODE; then
        export ANCROO_LOCAL_BUILD=y
        print_step "Dev mode: building ancroo-runner image from local source..."
        docker build \
            --build-arg BUILD_COMMIT="$(cd "$RUNNER_DIR" && git rev-parse --short HEAD 2>/dev/null || echo dev)" \
            -t ghcr.io/ancroo/ancroo-runner:latest \
            "$RUNNER_DIR"
        print_success "ancroo-runner image built from local source"
    else
        RUNNER_IMAGE="ghcr.io/ancroo/ancroo-runner:latest"
        print_step "Pulling runner image: ${RUNNER_IMAGE}"
        if docker pull "$RUNNER_IMAGE"; then
            print_success "Runner image pulled"
        else
            echo ""
            print_error "Could not pull ${RUNNER_IMAGE}"
            print_info "Check your Docker credentials or Internet connection"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_warning "Non-interactive mode: continuing without runner (image not available)"
                ENABLE_RUNNER=false
            elif ! confirm "Continue without the runner?" "n"; then
                print_info "Installation aborted — resolve the issue and try again"
                exit 1
            else
                ENABLE_RUNNER=false
            fi
        fi
    fi

    if $ENABLE_RUNNER; then
        ANCROO_INSTALL_OVERWRITE=y ANCROO_ENABLE_NOW=y \
            bash "$RUNNER_DIR/install-stack.sh" "$PROJECT_ROOT"
        unset ANCROO_INSTALL_OVERWRITE ANCROO_ENABLE_NOW
        $DEV_MODE && unset ANCROO_LOCAL_BUILD || true
    fi
fi

# ─────────────────────────────────────────────────────────
# ANCROO EXTENSION
# ─────────────────────────────────────────────────────────
if $ENABLE_EXTENSION; then
    print_header "Ancroo Extension"

    if $DEV_MODE; then
        print_info "Dev mode: building extension from local source"
        bash "$WEB_DIR/build.sh"
    else
        EXTENSION_OK=false

        if ! command -v gh &>/dev/null; then
            print_error "gh CLI is not installed — cannot download the extension"
            print_info "Install it from: https://cli.github.com"
        elif ! gh auth status &>/dev/null 2>&1; then
            print_error "gh CLI is not authenticated — cannot download the extension"
            print_info "Run: gh auth login"
        else
            print_step "Downloading latest build artifact from GitHub Actions..."
            if gh run download \
                --repo ancroo/ancroo-web \
                --name ancroo-web-extension \
                --dir "$WEB_DIR/dist" 2>/dev/null; then
                print_success "Ancroo extension downloaded to ${WEB_DIR}/dist/"
                EXTENSION_OK=true
            else
                print_error "Artifact download failed"
                print_info "Check that the GitHub Actions build has completed successfully"
            fi
        fi

        if ! $EXTENSION_OK; then
            echo ""
            print_warning "The browser extension could not be installed"
            print_info "The extension is required for the full Ancroo experience"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_warning "Non-interactive mode: continuing without extension"
            elif ! confirm "Continue installation without the extension?" "n"; then
                print_info "Installation aborted — resolve the issue above and run the installer again"
                exit 1
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────
# FINAL SERVICE START
# ─────────────────────────────────────────────────────────

# Ensure ALL services (base + backend + runner) are running with the final COMPOSE_FILE
print_header "Starting All Services"
cd "$PROJECT_ROOT"
docker compose up -d

# Verify backend/runner containers are actually running (not just created)
if $ENABLE_BACKEND; then
    _backend_ok=false
    for _i in $(seq 1 15); do
        if docker ps --format '{{.Names}}' | grep -q '^ancroo-backend$'; then
            _backend_ok=true
            break
        fi
        sleep 2
    done
    if $_backend_ok; then
        print_success "ancroo-backend running"
    else
        print_error "ancroo-backend failed to start"
        print_info "Check: docker compose logs ancroo-backend"
    fi
fi

if $ENABLE_RUNNER; then
    _runner_ok=false
    for _i in $(seq 1 15); do
        if docker ps --format '{{.Names}}' | grep -q '^ancroo-runner$'; then
            _runner_ok=true
            break
        fi
        sleep 2
    done
    if $_runner_ok; then
        print_success "ancroo-runner running"
    else
        print_error "ancroo-runner failed to start"
        print_info "Check: docker compose logs ancroo-runner"
    fi
fi

# ─────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────

# Read final state from .env
HOST_IP=$(grep "^HOST_IP=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "localhost")

# --- Wait for containers to become healthy ---
echo ""
print_step "Waiting for all containers to become healthy..."
_wait_max=300
_wait_elapsed=0
_wait_interval=5
while [[ $_wait_elapsed -lt $_wait_max ]]; do
    _healthy=0
    _total=0
    _all_ready=true
    for _ctr in $(docker compose ps --format '{{.Name}}' 2>/dev/null); do
        _total=$((_total + 1))
        _h=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$_ctr" 2>/dev/null)
        _s=$(docker inspect --format='{{.State.Status}}' "$_ctr" 2>/dev/null || echo "unknown")
        if [[ "$_s" == "running" ]] && [[ "$_h" == "healthy" || "$_h" == "no-healthcheck" ]]; then
            _healthy=$((_healthy + 1))
        else
            _all_ready=false
        fi
    done
    if $_all_ready; then
        break
    fi
    printf "\r  ⏳  %d/%d containers healthy (%ds elapsed)...    " "$_healthy" "$_total" "$_wait_elapsed"
    sleep "$_wait_interval"
    _wait_elapsed=$((_wait_elapsed + _wait_interval))
done
printf "\r%80s\r" ""
if $_all_ready; then
    print_success "All $_total containers healthy"
else
    print_warning "$_healthy/$_total containers healthy after ${_wait_elapsed}s"
fi

# --- Final summary ---
echo ""
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}${GREEN}  Installation complete!${NC}"
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Container Status:${NC}"
_fp_warnings=()
for _fp_ctr in $(docker compose ps --format '{{.Name}}' 2>/dev/null); do
    _fp_health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$_fp_ctr" 2>/dev/null)
    _fp_state=$(docker inspect --format='{{.State.Status}}' "$_fp_ctr" 2>/dev/null || echo "unknown")
    if [[ "$_fp_state" == "running" ]]; then
        if [[ "$_fp_health" == "healthy" || "$_fp_health" == "no-healthcheck" ]]; then
            print_success "$_fp_ctr"
        else
            print_warning "$_fp_ctr ($_fp_health)"
            _fp_warnings+=("$_fp_ctr is not healthy ($_fp_health)")
        fi
    else
        print_error "$_fp_ctr ($_fp_state)"
        _fp_warnings+=("$_fp_ctr is not running ($_fp_state)")
    fi
done
echo ""
echo -e "  ${BOLD}Services:${NC}"
echo -e "    Open WebUI:     ${CYAN}http://${HOST_IP}:8080${NC}"
echo -e "    Homepage:       ${CYAN}http://${HOST_IP}${NC}"
echo -e "    Ollama API:     ${CYAN}http://${HOST_IP}:11434${NC}"
echo -e "    Adminer:        ${CYAN}http://${HOST_IP}:8081${NC}"
echo -e "    BookStack:      ${CYAN}http://${HOST_IP}:8875${NC}"

N8N_PORT_FINAL=$(grep "^N8N_PORT=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "5678")
echo ""
echo -e "  ${BOLD}n8n (Workflow Automation):${NC}"
echo -e "    URL:      ${CYAN}http://${HOST_IP}:${N8N_PORT_FINAL}${NC}"
echo -e "    Create an admin account on first access"

BOOKSTACK_PASS_FINAL=$(grep "^BOOKSTACK_ADMIN_PASSWORD=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
BOOKSTACK_USER_FINAL=$(grep "^BOOKSTACK_ADMIN_EMAIL=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
if [[ -n "$BOOKSTACK_USER_FINAL" && -n "$BOOKSTACK_PASS_FINAL" ]]; then
    echo ""
    echo -e "  ${BOLD}BookStack Admin:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8875${NC}"
    echo -e "    Login:    ${BOLD}${BOOKSTACK_USER_FINAL}${NC} / ${YELLOW}${BOOKSTACK_PASS_FINAL}${NC}"
fi

echo ""
echo -e "  ${BOLD}STT (Speech-to-Text):${NC}"
if [[ "$STT_ENGINE" == "speaches" ]]; then
    echo -e "    Speaches:       ${CYAN}http://${HOST_IP}:8100${NC}"
elif [[ "$STT_ENGINE" == "whisper-rocm" ]]; then
    echo -e "    Whisper ROCm:   ${CYAN}http://${HOST_IP}:8002${NC}"
fi

if [[ -n "${ollama_model:-}" ]]; then
    echo ""
    echo -e "  ${BOLD}Ollama Model:${NC}"
    if [[ "$ollama_model_pulled" == "y" ]]; then
        echo -e "    ${ollama_model} — ready"
    else
        echo -e "    ${ollama_model} — ${YELLOW}not yet pulled${NC}"
        echo -e "    docker exec ollama ollama pull ${ollama_model}"
    fi
fi

if $ENABLE_BACKEND; then
    echo ""
    echo -e "  ${BOLD}Ancroo Backend:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8900${NC}"
    echo -e "    Admin:    ${CYAN}http://${HOST_IP}:8900/admin${NC}"
fi

if $ENABLE_RUNNER; then
    echo ""
    echo -e "  ${BOLD}Ancroo Runner:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8510${NC}"
    echo -e "    Plugins:  ${CYAN}${PROJECT_ROOT}/data/ancroo-runner/plugins${NC}"
fi

if $ENABLE_EXTENSION; then
    echo ""
    echo -e "  ${BOLD}Ancroo Extension (load in Chrome):${NC}"
    echo "    1. Open chrome://extensions"
    echo "    2. Enable Developer mode"
    echo "    3. Load unpacked → select: ${WEB_DIR}/dist/"
    echo "    4. Set backend URL: http://${HOST_IP}:8900"
fi

if $ENABLE_BACKEND; then
    echo ""
    echo -e "  ${BOLD}Workflows:${NC}"
    echo "    Import example workflows via the admin panel:"
    echo -e "    ${CYAN}http://${HOST_IP}:8900/admin${NC} → Import Workflow"
fi

echo ""
echo -e "  ${BOLD}Manage stack:${NC}"
echo "    ./stack.sh status          — container status"
echo "    ./stack.sh urls            — all service URLs"
echo "    ./stack.sh verify          — health checks"
echo "    ./stack.sh gpu <mode>      — switch GPU (cpu/nvidia/rocm)"
echo "    ./stack.sh stt <engine>    — switch STT (speaches/whisper-rocm)"

# --- Repeat all warnings at the very end ---
if [[ ${#_fp_warnings[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}${YELLOW}  ⚠  Warnings${NC}"
    echo -e "  ${BOLD}${YELLOW}════════════════════════════════════════════════${NC}"
    for _w in "${_fp_warnings[@]}"; do
        print_warning "$_w"
    done
    echo ""
    print_warning "Check with: docker compose ps"
fi
echo ""
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
