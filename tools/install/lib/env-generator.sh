#!/bin/bash
# env-generator.sh — Generate .env for ancroo-stack base installation

detect_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        ip=$(hostname 2>/dev/null)
    fi
    echo "${ip:-localhost}"
}

generate_password() {
    local result=""
    local attempts=0
    while [[ ${#result} -lt 32 ]] && [[ $attempts -lt 5 ]]; do
        result+=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9') || true
        attempts=$((attempts + 1))
    done
    if [[ ${#result} -lt 32 ]]; then
        print_error "Failed to generate secure password"
        exit 1
    fi
    echo "${result:0:32}"
}

generate_secret_key() {
    openssl rand -base64 48 2>/dev/null | tr -d '\n' || generate_password
}

detect_amd_gpu_arch() {
    # Read GPU architecture from KFD topology (no userspace tools needed)
    local gfx_version=""
    for node_dir in /sys/class/kfd/kfd/topology/nodes/*/; do
        local props="$node_dir/properties"
        [[ -f "$props" ]] || continue
        local target
        target=$(grep '^gfx_target_version' "$props" 2>/dev/null | awk '{print $2}')
        # Skip CPU nodes (gfx_target_version 0)
        if [[ -n "$target" && "$target" != "0" ]]; then
            gfx_version="$target"
            break
        fi
    done
    # Fallback: try rocminfo
    if [[ -z "$gfx_version" ]] && command -v rocminfo &>/dev/null; then
        gfx_version=$(rocminfo 2>/dev/null | grep -oP 'gfx\K[0-9]+' | head -1)
    fi
    echo "$gfx_version"
}

write_rocm_gpu_env() {
    # Detect GPU and write appropriate env vars for ROCm mode
    local gfx_version
    gfx_version=$(detect_amd_gpu_arch)

    # Always write ROCm env vars to suppress Docker Compose warnings
    # about unset variables referenced in compose.gpu-rocm.yml
    local ollama_tag=""
    local hip_devices=""
    local flash_attention=""
    local hsa_override=""

    if [[ -z "$gfx_version" ]]; then
        print_warning "No AMD GPU detected — ROCm will run in CPU fallback mode"
    else
        # gfx_target_version format: MMPPP (e.g. 110501 = gfx1151, 110000 = gfx1100)
        case "$gfx_version" in
            110501|1151|110500|1105)
                # gfx1151 (RDNA 4 / Strix Halo) or gfx1105 (RDNA 3 iGPU)
                # ROCm 7.x supports gfx1151 natively. The stable ollama:rocm tag ships ROCm 6.x which crashes.
                print_info "GPU: gfx${gfx_version} (RDNA 4 iGPU) detected — using ROCm 7.x backend"
                ollama_tag="0.17.8-rc1-rocm"
                hip_devices="0"
                flash_attention="true"
                ;;
            110000|110100|110200|1100|1101|1102)
                print_info "GPU: RDNA 3 detected — using native HIP backend"
                ;;
            103000|1030)
                print_info "GPU: RDNA 2 detected — using native HIP backend"
                ;;
            90800|90a00|94200|95000|908|90a|942|950)
                print_info "GPU: AMD Instinct detected — using native HIP backend"
                ;;
            *)
                print_warning "GPU architecture $gfx_version not explicitly supported"
                print_warning "HIP will be attempted — if issues occur, set HSA_OVERRIDE_GFX_VERSION in .env"
                ;;
        esac
    fi

    cat >> "$PROJECT_ROOT/.env" << EOF

# ROCm GPU configuration (auto-detected)
OLLAMA_IMAGE_TAG="${ollama_tag}"
HIP_VISIBLE_DEVICES="${hip_devices}"
OLLAMA_FLASH_ATTENTION="${flash_attention}"
HSA_OVERRIDE_GFX_VERSION="${hsa_override}"
EOF
}

create_base_env() {
    local timezone="$1"
    local gpu_mode="$2"
    local stt_engine="${3:-speaches}"
    local hostname
    hostname=$(detect_local_ip)
    # Export for use in install.sh (Homepage config, summary output)
    DETECTED_HOST_IP="$hostname"

    # Helper: read existing value from .env, strip quotes
    _old_env() {
        grep "^${1}=" "$PROJECT_ROOT/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo ""
    }

    local has_old_env=false
    [[ -f "$PROJECT_ROOT/.env" ]] && has_old_env=true

    local pg_user="ancroo"
    local pg_pass
    local pg_db="ancroo"

    # Preserve existing credentials when data directories exist
    if $has_old_env; then
        local _old_pg_pass
        _old_pg_pass=$(_old_env POSTGRES_PASSWORD)
        if [[ -n "$_old_pg_pass" ]]; then
            pg_pass="$_old_pg_pass"
            print_info "Preserving existing PostgreSQL password"
        fi
    fi
    if [[ -z "${pg_pass:-}" ]]; then
        if [[ -d "$PROJECT_ROOT/data/postgresql" ]] && [[ -n "$(ls -A "$PROJECT_ROOT/data/postgresql" 2>/dev/null)" ]]; then
            print_warning "PostgreSQL data exists but no password found in .env!"
            print_warning "Either add the old password to .env or delete data/postgresql"
        fi
        pg_pass=$(generate_password)
    fi

    local docker_gid
    docker_gid=$(detect_docker_gid)

    # Preserve or generate secrets
    local webui_secret
    if $has_old_env; then webui_secret=$(_old_env WEBUI_SECRET_KEY); fi
    [[ -z "${webui_secret:-}" ]] && webui_secret=$(generate_secret_key)

    local n8n_encryption_key
    if $has_old_env; then n8n_encryption_key=$(_old_env N8N_ENCRYPTION_KEY); fi
    [[ -z "${n8n_encryption_key:-}" ]] && n8n_encryption_key=$(openssl rand -hex 16)

    local bookstack_app_key
    if $has_old_env; then bookstack_app_key=$(_old_env BOOKSTACK_APP_KEY); fi
    [[ -z "${bookstack_app_key:-}" ]] && bookstack_app_key="base64:$(openssl rand -base64 32)"

    local bookstack_db_pass
    if $has_old_env; then bookstack_db_pass=$(_old_env BOOKSTACK_DB_PASSWORD); fi
    [[ -z "${bookstack_db_pass:-}" ]] && bookstack_db_pass=$(generate_password)

    local bookstack_db_root_pass
    if $has_old_env; then bookstack_db_root_pass=$(_old_env BOOKSTACK_DB_ROOT_PASSWORD); fi
    [[ -z "${bookstack_db_root_pass:-}" ]] && bookstack_db_root_pass=$(generate_password)

    local bookstack_admin_email
    if $has_old_env; then bookstack_admin_email=$(_old_env BOOKSTACK_ADMIN_EMAIL); fi
    [[ -z "${bookstack_admin_email:-}" ]] && bookstack_admin_email="admin@admin.com"

    local bookstack_admin_pass
    if $has_old_env; then bookstack_admin_pass=$(_old_env BOOKSTACK_ADMIN_PASSWORD); fi
    [[ -z "${bookstack_admin_pass:-}" ]] && bookstack_admin_pass=$(openssl rand -base64 12)

    # Preserve n8n/backend credentials if they exist
    local n8n_admin_email n8n_admin_password ancroo_n8n_api_key ancroo_secret_key
    if $has_old_env; then
        n8n_admin_email=$(_old_env N8N_ADMIN_EMAIL)
        n8n_admin_password=$(_old_env N8N_ADMIN_PASSWORD)
        ancroo_n8n_api_key=$(_old_env ANCROO_N8N_API_KEY)
        ancroo_secret_key=$(_old_env ANCROO_SECRET_KEY)
    fi

    if $has_old_env; then
        print_info "Preserving existing credentials from .env"
    fi

    # Build COMPOSE_FILE
    local compose_file="docker-compose.yml:docker-compose.ports.yml"
    if [[ "$gpu_mode" != "cpu" ]]; then
        compose_file+=":compose.gpu-${gpu_mode}.yml"
    fi
    compose_file+=":compose.${stt_engine}.yml"

    cat > "$PROJECT_ROOT/.env" << EOF
# ancroo-stack — Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# System
TZ="${timezone}"
GPU_MODE="${gpu_mode}"
STT_ENGINE="${stt_engine}"
COMPOSE_FILE="${compose_file}"

# PostgreSQL
POSTGRES_USER="${pg_user}"
POSTGRES_PASSWORD="${pg_pass}"
POSTGRES_DB="${pg_db}"
DATABASE_URL="postgresql://${pg_user}:${pg_pass}@postgres:5432/${pg_db}"

# Open WebUI
WEBUI_SECRET_KEY="${webui_secret}"

# Homepage Dashboard
PUID="$(id -u)"
DOCKER_GID="${docker_gid}"

# Host (for access URLs)
HOST_IP="${hostname}"

# n8n
N8N_ENCRYPTION_KEY="${n8n_encryption_key}"
N8N_DB="ancroo_n8n"
N8N_PORT="5678"

# BookStack
BOOKSTACK_APP_KEY="${bookstack_app_key}"
BOOKSTACK_APP_URL="http://${hostname}:8875"
BOOKSTACK_DB_PASSWORD="${bookstack_db_pass}"
BOOKSTACK_DB_ROOT_PASSWORD="${bookstack_db_root_pass}"
BOOKSTACK_ADMIN_EMAIL="${bookstack_admin_email}"
BOOKSTACK_ADMIN_PASSWORD="${bookstack_admin_pass}"
BOOKSTACK_PORT="8875"

# Adminer
ADMINER_PORT="8081"

# STT
SPEACHES_PORT="8100"
WHISPER_ROCM_PORT="8002"
EOF

    # Append preserved credentials (n8n provisioning, backend)
    if [[ -n "${n8n_admin_email:-}" ]]; then
        echo "N8N_ADMIN_EMAIL=\"${n8n_admin_email}\"" >> "$PROJECT_ROOT/.env"
    fi
    if [[ -n "${n8n_admin_password:-}" ]]; then
        echo "N8N_ADMIN_PASSWORD=\"${n8n_admin_password}\"" >> "$PROJECT_ROOT/.env"
    fi
    if [[ -n "${ancroo_n8n_api_key:-}" ]]; then
        echo "ANCROO_N8N_API_KEY=\"${ancroo_n8n_api_key}\"" >> "$PROJECT_ROOT/.env"
    fi
    if [[ -n "${ancroo_secret_key:-}" ]]; then
        echo "ANCROO_SECRET_KEY=\"${ancroo_secret_key}\"" >> "$PROJECT_ROOT/.env"
    fi

    chmod 640 "$PROJECT_ROOT/.env"

    # Auto-detect GPU architecture and write backend-specific vars
    if [[ "$gpu_mode" == "rocm" ]]; then
        write_rocm_gpu_env
    fi

    print_success ".env created"
}

create_password_summary() {
    local summary_dir="$PROJECT_ROOT/logs"
    mkdir -p "$summary_dir"
    local summary_file="$summary_dir/install-summary-$(date '+%Y%m%d-%H%M%S').txt"

    local pg_pass
    pg_pass=$(grep '^POSTGRES_PASSWORD=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

    cat > "$summary_file" << EOF
ancroo-stack — Installation Summary
==============================
Generated: $(date '+%Y-%m-%d %H:%M:%S')

PostgreSQL:
  User:     $(grep '^POSTGRES_USER=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)
  Password: ${pg_pass}
  Database: $(grep '^POSTGRES_DB=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

GPU Mode: $(grep '^GPU_MODE=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

Access URLs:
  Open WebUI: http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-):8080
  Homepage:   http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)
  Ollama API: http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-):11434
EOF

    chmod 600 "$summary_file"
    print_success "Credentials saved: $summary_file"
}
