# Security Guide

## Credentials

All passwords are auto-generated during installation (32+ character random strings) and stored in `.env`.

- File permissions are set to `600` (owner-only) by `install.sh`
- `.env` is excluded from version control (`.gitignore`)
- Back up `.env` securely — it contains all service credentials

## Network Exposure

Services are exposed on individual ports **without TLS encryption**. Only use in trusted networks (home lab, VPN).

### Firewall

Restrict access to necessary ports:

```bash
sudo ufw allow 8080/tcp    # Open WebUI
sudo ufw allow 11434/tcp   # Ollama API
sudo ufw enable
```

## First User

**Open WebUI:** The first account created gets admin privileges. Create your account immediately after installation to prevent unauthorized access.

## Password Rotation

### PostgreSQL

```bash
docker compose stop
docker compose start postgres
docker exec postgres psql -U ancroo -c "ALTER USER ancroo PASSWORD 'new-password';"

# Update POSTGRES_PASSWORD and all DATABASE_URL entries in .env
docker compose up -d
```

## Vulnerability Reporting

Report security issues privately via [GitHub Security Advisory](https://github.com/ancroo/ancroo-stack/security/advisories/new).

Response time: within 48 hours.
