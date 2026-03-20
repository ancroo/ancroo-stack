#!/bin/bash
# Initialize PostgreSQL databases and extensions
# Runs automatically on first PostgreSQL container startup
set -e

PGUSER="${POSTGRES_USER:-postgres}"
MAIN_DB="${POSTGRES_DB:-ancroo}"
N8N_DB="${N8N_DB:-ancroo_n8n}"

echo "Initializing databases..."

# Create n8n database (separate from main DB)
psql -v ON_ERROR_STOP=1 --username "$PGUSER" <<-EOSQL
    SELECT 'CREATE DATABASE ${N8N_DB}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${N8N_DB}')\gexec
EOSQL

# Enable pgvector extension in main database
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "$MAIN_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

echo "Database initialization completed"
