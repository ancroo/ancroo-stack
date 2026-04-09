# ancroo-stack — Self-Hosted Modular Docker Stack

**Language:** Bash, Docker Compose YAML
**License:** Apache 2.0

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Guided interactive installer (GPU, STT, .env generation) |
| `stack.sh` | Runtime management (status, health, URLs, GPU/STT switching) |
| `rebuild.sh` | Rebuild local images (backend, runner, web) |
| `uninstall.sh` | Complete cleanup (with dry-run) |
| `docker-compose.yml` | Base services definition |
| `docker-compose.ports.yml` | Port mappings overlay |
| `compose.gpu-nvidia.yml` | NVIDIA GPU overlay |
| `compose.gpu-rocm.yml` | AMD ROCm GPU overlay |
| `compose.speaches.yml` | Speaches STT overlay |
| `compose.whisper-rocm.yml` | Whisper-ROCm STT overlay |
| `.env` | Generated config (not in Git, 600 perms) |
| `.env.example` | Config documentation template |
| `tools/install/lib/common.sh` | Shared logging/color functions |
| `tools/install/lib/env-generator.sh` | .env creation logic |
| `tools/install/lib/validation.sh` | Pre-flight checks |
| `tools/install/lib/n8n-provision.sh` | n8n admin setup |

## Compose Architecture (Base + Overlays)

`COMPOSE_FILE` env var chains YAML files with `:`:

```
# CPU + Speaches (minimal)
docker-compose.yml:docker-compose.ports.yml:compose.speaches.yml

# NVIDIA + Speaches + Backend + Runner
docker-compose.yml:docker-compose.ports.yml:compose.gpu-nvidia.yml:compose.speaches.yml:../ancroo-backend/module/compose.yml:...
```

## Base Services (always included)

| Service | Port | Purpose |
|---------|------|---------|
| PostgreSQL 16 + pgvector | 5432 | Shared database |
| Ollama | 11434 | Local LLM runtime |
| Open WebUI | 8080 | Chat interface + RAG |
| Homepage | 80 | Service dashboard |
| Adminer | 8081 | Database admin |
| n8n | 5678 | Workflow automation |
| BookStack | 8875 | Documentation wiki |

## Module System

Modules live in `modules/` (symlinked from sibling repos or local):

| Module | Source | Status |
|--------|--------|--------|
| `ancroo-backend` | `../../ancroo-backend/module/` (symlink) | Active |
| `ancroo-runner` | `../../ancroo-runner/module/` (symlink) | Active |
| `ssl` | Local (`modules/ssl/`) | Experimental |
| `sso` | Local (`modules/sso/`) | Experimental |

Each module has: `module.conf` (metadata), `compose.yml`, optional `module.env`, `setup.sh`, `post-enable.sh`.

## Cross-Repo Dependencies

**Hosts services for:**
- ancroo-backend (PostgreSQL, Ollama, Whisper, n8n, Keycloak)
- ancroo-runner (network, plugin volume)

**install.sh auto-clones:**
- `ancroo-backend`, `ancroo-runner`, `ancroo-web`, `ancroo` (meta)

**Sibling repo layout expected:**
```
/parent/
├── ancroo-stack/     (this repo)
├── ancroo-backend/   (module/ symlinked)
├── ancroo-runner/    (module/ symlinked)
├── ancroo-web/       (cloned, not integrated)
└── ancroo/           (meta, workflow definitions)
```

## Important: Host vs Container Paths

Stack modules use **host paths**, not container paths. When developing inside a dev container, compose file paths must reference the host filesystem.

## Key .env Variables

| Variable | Purpose |
|----------|---------|
| `GPU_MODE` | `nvidia`, `rocm`, or `cpu` |
| `STT_ENGINE` | `speaches` or `whisper-rocm` |
| `COMPOSE_FILE` | Colon-separated compose file chain |
| `POSTGRES_PASSWORD` | Auto-generated database password |
| `DATABASE_URL` | PostgreSQL connection string |
| `WEBUI_SECRET_KEY` | Open WebUI secret |
| `N8N_ENCRYPTION_KEY` | n8n encryption key |

## Management

```bash
./stack.sh status       # Container status + health
./stack.sh urls         # Service URLs
./stack.sh gpu          # Switch GPU mode
./stack.sh stt          # Switch STT engine
./stack.sh verify       # Verify stack health
./rebuild.sh            # Rebuild local images
./rebuild.sh --no-cache # Full rebuild
```
