#!/bin/bash
# stack.sh — ancroo-stack Management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"

# Load common functions
if [[ -f "$PROJECT_ROOT/tools/install/lib/common.sh" ]]; then
    source "$PROJECT_ROOT/tools/install/lib/common.sh"
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
    print_error() { echo -e "  ${RED}✗${NC} $1" >&2; }
    print_success() { echo -e "  ${GREEN}✓${NC} $1"; }
    print_info() { echo -e "  ${CYAN}→${NC} $1"; }
    print_warning() { echo -e "  ${YELLOW}⚠${NC} $1"; }
    print_step() { echo -e "\n  ${BOLD}$1${NC}"; }
    print_header() {
        echo ""
        echo -e "${BOLD}${BLUE}  $1${NC}"
        echo -e "${BLUE}  $(printf '=%.0s' $(seq 1 ${#1}))${NC}"
        echo ""
    }
fi

# ─── .env Management ─────────────────────────────────────────
ENV_LOADED=false

load_env() {
    if $ENV_LOADED; then return 0; fi
    if [[ ! -f "$ENV_FILE" ]]; then
        print_error ".env not found. Run ./install.sh first"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key=$value"
    done < "$ENV_FILE"
    ENV_LOADED=true
}

update_env_var() {
    local key="$1"
    local value="$2"
    local temp_file
    temp_file=$(mktemp)

    local found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^${key}= ]]; then
            echo "${key}=\"${value}\"" >> "$temp_file"
            found=true
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$ENV_FILE"

    if ! $found; then
        echo "${key}=\"${value}\"" >> "$temp_file"
    fi

    mv -f "$temp_file" "$ENV_FILE"
    ENV_LOADED=false
}

# ─── COMPOSE_FILE Builder ────────────────────────────────────
build_compose_file() {
    load_env
    local gpu_mode="${GPU_MODE:-cpu}"
    local stt_engine="${STT_ENGINE:-speaches}"

    local compose="docker-compose.yml:docker-compose.ports.yml"

    # GPU override
    if [[ "$gpu_mode" != "cpu" ]] && [[ -f "$PROJECT_ROOT/compose.gpu-${gpu_mode}.yml" ]]; then
        compose+=":compose.gpu-${gpu_mode}.yml"
    fi

    # STT engine
    if [[ -f "$PROJECT_ROOT/compose.${stt_engine}.yml" ]]; then
        compose+=":compose.${stt_engine}.yml"
    fi

    # External projects (ancroo-backend, ancroo-runner)
    local parent_dir
    parent_dir="$(dirname "$PROJECT_ROOT")"
    if [[ -f "$parent_dir/ancroo-backend/module/compose.yml" ]]; then
        compose+=":../ancroo-backend/module/compose.yml"
        if [[ -f "$parent_dir/ancroo-backend/module/compose.ports.yml" ]]; then
            compose+=":../ancroo-backend/module/compose.ports.yml"
        fi
    fi
    if [[ -f "$parent_dir/ancroo-runner/module/compose.yml" ]]; then
        compose+=":../ancroo-runner/module/compose.yml"
        if [[ -f "$parent_dir/ancroo-runner/module/compose.ports.yml" ]]; then
            compose+=":../ancroo-runner/module/compose.ports.yml"
        fi
    fi

    echo "$compose"
}

rebuild_compose() {
    local new_compose
    new_compose=$(build_compose_file)
    update_env_var "COMPOSE_FILE" "$new_compose"
    load_env
    print_success "COMPOSE_FILE updated: $new_compose"
}

# ─── Commands ────────────────────────────────────────────────

cmd_status() {
    print_header "Stack Status"
    cd "$PROJECT_ROOT"
    load_env
    docker compose ps
}

cmd_verify() {
    load_env
    local _VRF_PASSED=0
    local _VRF_FAILED=0
    local host="${HOST_IP:-localhost}"
    local docker_info
    docker_info=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || echo "")

    print_header "Stack Verification"

    echo -e "  ${BOLD}Containers:${NC}"
    echo ""

    _verify_container "PostgreSQL"   "postgres"    "$docker_info"
    _verify_container "Ollama"       "ollama"      "$docker_info"
    _verify_container "Open WebUI"   "open-webui"  "$docker_info"
    _verify_container "Homepage"     "homepage"    "$docker_info"
    _verify_container "Adminer"      "adminer"     "$docker_info"
    _verify_container "n8n"          "n8n"         "$docker_info"
    _verify_container "BookStack"    "bookstack"   "$docker_info"
    _verify_container "BookStack DB" "bookstack-db" "$docker_info"

    # STT
    local stt="${STT_ENGINE:-speaches}"
    if [[ "$stt" == "speaches" ]]; then
        _verify_container "Speaches" "speaches" "$docker_info"
    elif [[ "$stt" == "whisper-rocm" ]]; then
        _verify_container "Whisper ROCm" "whisper-rocm" "$docker_info"
    fi

    # External projects
    _verify_container "Ancroo Backend" "ancroo-backend" "$docker_info" true
    _verify_container "Ancroo Runner"  "ancroo-runner"  "$docker_info" true

    echo ""
    echo -e "  ${BOLD}HTTP Health Checks:${NC}"
    echo ""

    _verify_http "Homepage"   "http://${host}"
    _verify_http "Open WebUI" "http://${host}:8080"
    _verify_http "Ollama API" "http://${host}:11434/api/tags"
    _verify_http "Adminer"    "http://${host}:${ADMINER_PORT:-8081}"
    _verify_http "n8n"        "http://${host}:${N8N_PORT:-5678}/healthz"
    _verify_http "BookStack"  "http://${host}:${BOOKSTACK_PORT:-8875}/status"

    if [[ "$stt" == "speaches" ]]; then
        _verify_http "Speaches" "http://${host}:${SPEACHES_PORT:-8100}/health"
    elif [[ "$stt" == "whisper-rocm" ]]; then
        _verify_http "Whisper ROCm" "http://${host}:${WHISPER_ROCM_PORT:-8002}/health"
    fi

    echo ""
    local total=$((_VRF_PASSED + _VRF_FAILED))
    if [[ $_VRF_FAILED -eq 0 ]]; then
        print_success "All checks passed ($_VRF_PASSED/$total)"
    else
        print_error "$_VRF_FAILED check(s) failed ($_VRF_PASSED/$total passed)"
    fi
    echo ""
    return $((_VRF_FAILED > 0 ? 1 : 0))
}

_verify_container() {
    local label="$1"
    local container="$2"
    local docker_info="$3"
    local optional="${4:-false}"

    local line
    line=$(echo "$docker_info" | grep "^${container}|" || echo "")
    if [[ -n "$line" ]]; then
        local cstatus="${line##*|}"
        if [[ "$cstatus" == *"(healthy)"* ]]; then
            printf "  ${GREEN}✓${NC}  %-25s healthy\n" "$label"
        else
            printf "  ${YELLOW}~${NC}  %-25s running (not yet healthy)\n" "$label"
        fi
        _VRF_PASSED=$((_VRF_PASSED + 1))
    else
        if $optional; then
            printf "  ${CYAN}-${NC}  %-25s not installed\n" "$label"
        else
            printf "  ${RED}✗${NC}  %-25s not running\n" "$label"
            _VRF_FAILED=$((_VRF_FAILED + 1))
        fi
    fi
}

_verify_http() {
    local label="$1"
    local url="$2"
    local code
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
        printf "  ${GREEN}✓${NC}  %-25s HTTP %s\n" "$label" "$code"
        _VRF_PASSED=$((_VRF_PASSED + 1))
    else
        printf "  ${RED}✗${NC}  %-25s HTTP %s (unreachable)\n" "$label" "$code"
        _VRF_FAILED=$((_VRF_FAILED + 1))
    fi
}

cmd_urls() {
    load_env
    local host="${HOST_IP:-localhost}"

    echo ""
    echo -e "  ${BOLD}Service URLs:${NC}"
    echo ""

    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s${NC}\n"       "Homepage"   "$host"
    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:8080${NC}\n"  "Open WebUI" "$host"
    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:11434${NC}\n" "Ollama API" "$host"
    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n"    "Adminer"    "$host" "${ADMINER_PORT:-8081}"
    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n"    "n8n"        "$host" "${N8N_PORT:-5678}"
    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n"    "BookStack"  "$host" "${BOOKSTACK_PORT:-8875}"

    local stt="${STT_ENGINE:-speaches}"
    if [[ "$stt" == "speaches" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n" "Speaches" "$host" "${SPEACHES_PORT:-8100}"
    elif [[ "$stt" == "whisper-rocm" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n" "Whisper ROCm" "$host" "${WHISPER_ROCM_PORT:-8002}"
    fi

    # External projects
    local parent_dir
    parent_dir="$(dirname "$PROJECT_ROOT")"
    if [[ -f "$parent_dir/ancroo-backend/module/compose.yml" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n" "Ancroo Backend" "$host" "${ANCROO_PORT:-8900}"
    fi
    if [[ -f "$parent_dir/ancroo-runner/module/compose.yml" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n" "Ancroo Runner" "$host" "${ANCROO_RUNNER_PORT:-8510}"
    fi

    echo ""
}

cmd_gpu() {
    local new_mode="${1:-}"
    load_env

    if [[ -z "$new_mode" ]]; then
        echo ""
        echo -e "  GPU mode: ${BOLD}${GPU_MODE:-cpu}${NC}"
        echo ""
        echo "  Usage: $0 gpu <cpu|nvidia|rocm>"
        echo ""
        return 0
    fi

    case "$new_mode" in
        cpu|nvidia|rocm) ;;
        *)
            print_error "Invalid GPU mode: $new_mode (allowed: cpu, nvidia, rocm)"
            return 1
            ;;
    esac

    if [[ "$new_mode" != "cpu" ]] && [[ ! -f "$PROJECT_ROOT/compose.gpu-${new_mode}.yml" ]]; then
        print_error "GPU compose file not found: compose.gpu-${new_mode}.yml"
        return 1
    fi

    local old_mode="${GPU_MODE:-cpu}"
    if [[ "$old_mode" == "$new_mode" ]]; then
        print_info "GPU mode is already: $new_mode"
        return 0
    fi

    print_step "Switching GPU mode: $old_mode → $new_mode"

    update_env_var "GPU_MODE" "$new_mode"

    # Auto-detect AMD GPU architecture
    if [[ "$new_mode" == "rocm" ]]; then
        _detect_and_configure_rocm_gpu
    else
        update_env_var "OLLAMA_IMAGE_TAG" ""
        update_env_var "OLLAMA_VULKAN" ""
        update_env_var "HIP_VISIBLE_DEVICES" ""
        update_env_var "HSA_OVERRIDE_GFX_VERSION" ""
    fi

    # Update Speaches image tag based on GPU mode
    if [[ "$new_mode" == "nvidia" ]]; then
        update_env_var "SPEACHES_IMAGE_TAG" "latest-cuda"
    else
        update_env_var "SPEACHES_IMAGE_TAG" "latest-cpu"
    fi

    rebuild_compose

    print_step "Restarting containers..."
    cd "$PROJECT_ROOT"
    docker compose up -d

    print_success "GPU mode switched: $old_mode → $new_mode"
}

_detect_and_configure_rocm_gpu() {
    local gfx_version=""
    for node_dir in /sys/class/kfd/kfd/topology/nodes/*/; do
        local props="$node_dir/properties"
        [[ -f "$props" ]] || continue
        local target
        target=$(grep '^gfx_target_version' "$props" 2>/dev/null | awk '{print $2}')
        if [[ -n "$target" && "$target" != "0" ]]; then
            gfx_version="$target"
            break
        fi
    done
    if [[ -z "$gfx_version" ]] && command -v rocminfo &>/dev/null; then
        gfx_version=$(rocminfo 2>/dev/null | grep -oP 'gfx\K[0-9]+' | head -1)
    fi

    if [[ -z "$gfx_version" ]]; then
        print_warning "No AMD GPU detected — ROCm will run in CPU fallback mode"
        return
    fi

    case "$gfx_version" in
        110501|1151|110500|1105)
            print_info "GPU: gfx${gfx_version} (RDNA 4 iGPU) detected — using ROCm 7.x backend"
            update_env_var "OLLAMA_IMAGE_TAG" "0.17.8-rc1-rocm"
            update_env_var "OLLAMA_FLASH_ATTENTION" "true"
            update_env_var "OLLAMA_VULKAN" ""
            update_env_var "HIP_VISIBLE_DEVICES" "0"
            update_env_var "HSA_OVERRIDE_GFX_VERSION" ""
            ;;
        110000|110100|110200|1100|1101|1102)
            print_info "GPU: RDNA 3 detected — using native HIP backend"
            update_env_var "OLLAMA_IMAGE_TAG" ""
            update_env_var "OLLAMA_VULKAN" ""
            update_env_var "HIP_VISIBLE_DEVICES" ""
            update_env_var "HSA_OVERRIDE_GFX_VERSION" ""
            ;;
        103000|1030)
            print_info "GPU: RDNA 2 detected — using native HIP backend"
            update_env_var "OLLAMA_IMAGE_TAG" ""
            update_env_var "OLLAMA_VULKAN" ""
            update_env_var "HIP_VISIBLE_DEVICES" ""
            update_env_var "HSA_OVERRIDE_GFX_VERSION" ""
            ;;
        90800|90a00|94200|95000|908|90a|942|950)
            print_info "GPU: AMD Instinct detected — using native HIP backend"
            update_env_var "OLLAMA_IMAGE_TAG" ""
            update_env_var "OLLAMA_VULKAN" ""
            update_env_var "HIP_VISIBLE_DEVICES" ""
            update_env_var "HSA_OVERRIDE_GFX_VERSION" ""
            ;;
        *)
            print_warning "GPU architecture $gfx_version not explicitly supported"
            print_warning "HIP will be attempted — if issues occur, set HSA_OVERRIDE_GFX_VERSION in .env"
            update_env_var "OLLAMA_IMAGE_TAG" ""
            update_env_var "OLLAMA_VULKAN" ""
            update_env_var "HIP_VISIBLE_DEVICES" ""
            ;;
    esac
}

cmd_stt() {
    local new_engine="${1:-}"
    load_env

    if [[ -z "$new_engine" ]]; then
        echo ""
        echo -e "  STT engine: ${BOLD}${STT_ENGINE:-speaches}${NC}"
        echo ""
        echo "  Usage: $0 stt <speaches|whisper-rocm>"
        echo ""
        return 0
    fi

    case "$new_engine" in
        speaches|whisper-rocm) ;;
        *)
            print_error "Invalid STT engine: $new_engine (allowed: speaches, whisper-rocm)"
            return 1
            ;;
    esac

    if [[ ! -f "$PROJECT_ROOT/compose.${new_engine}.yml" ]]; then
        print_error "STT compose file not found: compose.${new_engine}.yml"
        return 1
    fi

    local old_engine="${STT_ENGINE:-speaches}"
    if [[ "$old_engine" == "$new_engine" ]]; then
        print_info "STT engine is already: $new_engine"
        return 0
    fi

    print_step "Switching STT engine: $old_engine → $new_engine"

    # Stop old STT container
    cd "$PROJECT_ROOT"
    docker compose stop "$old_engine" 2>/dev/null || true
    docker compose rm -f "$old_engine" 2>/dev/null || true

    update_env_var "STT_ENGINE" "$new_engine"
    rebuild_compose

    print_step "Starting $new_engine..."
    docker compose up -d "$new_engine"

    print_success "STT engine switched: $old_engine → $new_engine"
}

# ─── Main ────────────────────────────────────────────────────
show_usage() {
    echo ""
    echo -e "  ${BOLD}ancroo-stack${NC} — Stack Management"
    echo ""
    echo "  Usage: $0 <command> [args]"
    echo ""
    echo "  Commands:"
    echo "    status              Show container status"
    echo "    verify              Run health checks"
    echo "    urls                Show service URLs"
    echo "    gpu [mode]          Show or switch GPU mode (cpu|nvidia|rocm)"
    echo "    stt [engine]        Show or switch STT engine (speaches|whisper-rocm)"
    echo "    rebuild-compose     Rebuild COMPOSE_FILE from current config"
    echo ""
}

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        status)           cmd_status ;;
        verify)           cmd_verify ;;
        urls)             cmd_urls ;;
        gpu)              cmd_gpu "${1:-}" ;;
        stt)              cmd_stt "${1:-}" ;;
        rebuild-compose)  rebuild_compose ;;
        help|--help|-h|"")
            show_usage
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
