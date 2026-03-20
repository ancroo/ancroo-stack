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

# Build services.yaml from core + enabled modules
# Usage: build_homepage_services
build_homepage_services() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    local output_file="$homepage_dir/services.yaml"
    local temp_file
    temp_file=$(mktemp)

    # Read enabled modules
    local enabled_modules=""
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        enabled_modules=$(grep '^ENABLED_MODULES=' "$PROJECT_ROOT/.env" | cut -d= -f2 | tr -d '"')
    fi

    # Load all module.env files first (for variable defaults)
    for module in $enabled_modules; do
        load_module_env "$module"
    done

    # Start with YAML header
    echo "---" > "$temp_file"

    # Always include core services
    local core_snippet="$PROJECT_ROOT/tools/config/homepage/homepage.yml"
    if [[ -f "$core_snippet" ]]; then
        # Skip comment lines, substitute variables, append
        grep -v '^#' "$core_snippet" | envsubst >> "$temp_file"
    fi

    # Add enabled modules
    for module in $enabled_modules; do
        local module_snippet="$PROJECT_ROOT/modules/$module/homepage.yml"
        if [[ -f "$module_snippet" ]]; then
            echo "" >> "$temp_file"
            grep -v '^#' "$module_snippet" | envsubst >> "$temp_file"
        fi
    done

    # Write to final location
    mkdir -p "$homepage_dir"
    mv "$temp_file" "$output_file"
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
  AI Tools:
    style: column
    columns: 1
  Knowledge:
    style: column
    columns: 1
  Automation:
    style: column
    columns: 2
  Speech:
    style: column
    columns: 3
  Administration:
    style: row
    columns: 3
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
