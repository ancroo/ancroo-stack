#!/bin/bash
# homepage.sh — Homepage dashboard configuration helpers

# Load module.env and export variables
# Usage: load_module_env <module_name>
load_module_env() {
    local module="$1"
    local env_file="$PROJECT_ROOT/modules/$module/module.env"

    if [[ -f "$env_file" ]]; then
        # Source and export each variable
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            # Remove quotes from value
            value="${value%\"}"
            value="${value#\"}"
            # Export only if not already set
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < "$env_file"
    fi
}

# Build services.yaml with all stack services
# Homepage expects exactly one "- Apps:" and one "- Infrastructure:" entry.
# Usage: build_homepage_services
build_homepage_services() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    local output_file="$homepage_dir/services.yaml"

    # Load env defaults for variable substitution
    # Note: only export port/host vars needed by envsubst — NOT COMPOSE_FILE,
    # which would leak into subprocesses and override .env updates by module installers.
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
        unset COMPOSE_FILE
    fi

    # Set defaults for port variables
    export ADMINER_PORT="${ADMINER_PORT:-8081}"
    export N8N_PORT="${N8N_PORT:-5678}"
    export BOOKSTACK_PORT="${BOOKSTACK_PORT:-8875}"
    export SPEACHES_PORT="${SPEACHES_PORT:-8100}"
    export WHISPER_ROCM_PORT="${WHISPER_ROCM_PORT:-8002}"
    export ANCROO_PORT="${ANCROO_PORT:-8900}"
    export ANCROO_RUNNER_PORT="${ANCROO_RUNNER_PORT:-8510}"

    mkdir -p "$homepage_dir"

    # Determine STT snippet
    local stt_engine="${STT_ENGINE:-speaches}"

    # Build services.yaml as a single merged document
    # Homepage requires exactly one list entry per group
    cat << YAML | envsubst > "$output_file"
---
- Apps:
    - Open WebUI:
        icon: sh-open-webui
        href: http://${HOST_IP}:8080
        description: LLM Chat Interface + RAG
        siteMonitor: http://open-webui:8080
        server: local
        container: open-webui
    - BookStack:
        icon: mdi-book-open-page-variant
        href: http://${HOST_IP}:${BOOKSTACK_PORT}
        description: Knowledge Base / Wiki
        siteMonitor: http://bookstack:80/status
        server: local
        container: bookstack
    - n8n:
        icon: mdi-sitemap
        href: http://${HOST_IP}:${N8N_PORT}
        description: Workflow Automation
        siteMonitor: http://n8n:5678
        server: local
        container: n8n
    - Ancroo Backend:
        icon: mdi-anchor
        href: http://${HOST_IP}:${ANCROO_PORT}/admin
        description: AI Workflow Backend
        siteMonitor: http://ancroo-backend:8000/health
        server: local
        container: ancroo-backend
- Infrastructure:
    - Ollama:
        icon: sh-ollama
        href: http://${HOST_IP}:11434
        description: LLM Backend API
        siteMonitor: http://ollama:11434
        server: local
        container: ollama
    - Adminer:
        icon: mdi-database
        href: http://${HOST_IP}:${ADMINER_PORT}
        description: Database Management UI
        siteMonitor: http://adminer:8080
        server: local
        container: adminer
    - Ancroo Runner:
        icon: mdi-play-circle-outline
        href: http://${HOST_IP}:${ANCROO_RUNNER_PORT}/docs
        description: Script Runner API
        siteMonitor: http://ancroo-runner:8000/health
        server: local
        container: ancroo-runner
YAML

    # Append STT entry to Infrastructure group
    if [[ "$stt_engine" == "whisper-rocm" ]]; then
        cat << YAML | envsubst >> "$output_file"
    - Whisper ROCm:
        icon: mdi-microphone
        href: http://${HOST_IP}:${WHISPER_ROCM_PORT}/docs
        description: Speech-to-Text (AMD ROCm GPU)
        siteMonitor: http://whisper-rocm:8000/health
        server: local
        container: whisper-rocm
YAML
    else
        cat << YAML | envsubst >> "$output_file"
    - Speaches:
        icon: mdi-microphone
        href: http://${HOST_IP}:${SPEACHES_PORT}
        description: Speech-to-Text Service (Whisper)
        siteMonitor: http://speaches:8000
        server: local
        container: speaches
YAML
    fi

    chmod 644 "$output_file"
}

# Create static homepage config files (settings, docker, widgets, bookmarks)
# Usage: create_homepage_static_configs
create_homepage_static_configs() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    mkdir -p "$homepage_dir"

    # settings.yaml
    cat > "$homepage_dir/settings.yaml" << 'EOF'
---
title: Ancroo
theme: dark
color: slate
headerStyle: clean
statusStyle: dot
layout:
  Apps:
    style: row
    columns: 2
  Infrastructure:
    style: row
    columns: 2
EOF

    # docker.yaml
    cat > "$homepage_dir/docker.yaml" << 'EOF'
---
local:
  socket: /var/run/docker.sock
EOF

    # widgets.yaml (empty for now)
    cat > "$homepage_dir/widgets.yaml" << 'EOF'
---
EOF

    # bookmarks.yaml
    cat > "$homepage_dir/bookmarks.yaml" << 'EOF'
---
- Links:
    - Ollama Models:
        - icon: sh-ollama
          href: https://ollama.com/library
    - Open WebUI Docs:
        - icon: sh-open-webui
          href: https://docs.openwebui.com
EOF
}

# Full homepage setup (called by install.sh)
# Usage: setup_homepage
setup_homepage() {
    # Export HOST_IP for envsubst
    export HOST_IP="${DETECTED_HOST_IP:-localhost}"

    create_homepage_static_configs
    build_homepage_services
    copy_homepage_assets

    print_success "Homepage configured"
}

# Copy branding assets (custom CSS/JS with embedded logo) to homepage config
# Usage: copy_homepage_assets
copy_homepage_assets() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    local logo_file="$PROJECT_ROOT/tools/config/homepage/images/ancroo-128.png"

    # Generate custom.css for branding
    cat > "$homepage_dir/custom.css" << 'CSSEOF'
/* Ancroo Homepage Branding */

#ancroo-branding {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  padding: 2rem 0 1rem 0;
}

#ancroo-branding img {
  height: 4rem;
  width: 4rem;
  border-radius: 0.75rem;
  filter: drop-shadow(0 4px 12px rgba(74, 158, 218, 0.4));
}

#ancroo-branding span {
  font-size: 2.5rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  background: linear-gradient(135deg, #6bb5e8 0%, #3a8fd4 40%, #1e5a8a 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  text-shadow: none;
}
CSSEOF

    # Generate custom.js with embedded base64 logo
    if [[ -f "$logo_file" ]]; then
        local logo_b64
        logo_b64=$(base64 -w0 "$logo_file")
        cat > "$homepage_dir/custom.js" << JSEOF
// Ancroo Homepage Branding — inject anchor logo + title above services
(function() {
  var LOGO_B64 = "${logo_b64}";

  function injectBranding() {
    var wrapper = document.getElementById("inner_wrapper");
    if (!wrapper || document.getElementById("ancroo-branding")) return;

    var brandDiv = document.createElement("div");
    brandDiv.id = "ancroo-branding";

    var img = document.createElement("img");
    img.src = "data:image/png;base64," + LOGO_B64;
    img.alt = "Ancroo";

    var span = document.createElement("span");
    span.textContent = "Ancroo";

    brandDiv.appendChild(img);
    brandDiv.appendChild(span);

    wrapper.insertBefore(brandDiv, wrapper.firstChild);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", injectBranding);
  } else {
    injectBranding();
  }

  new MutationObserver(function() {
    if (!document.getElementById("ancroo-branding")) injectBranding();
  }).observe(document.body, { childList: true, subtree: true });
})();
JSEOF
    fi
}
