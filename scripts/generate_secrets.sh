#!/usr/bin/env bash
# Create the files in ./secrets that docker-compose.observability.yml mounts as secrets.
#
# Idempotent: existing files are never overwritten, so re-running is safe and rotating a
# secret means deleting its file first. Passwords never appear on a command line.
#
# Requirements: bash, openssl, docker (bcrypt hashing runs in a pinned httpd image).
set -euo pipefail

cd "$(dirname "$0")/.."
readonly DIR=secrets
readonly HTPASSWD_IMAGE=httpd:2.4.69-alpine

umask 077
mkdir -p "$DIR"
# The directory keeps other host users out; files inside are 0644 so that every container
# user (nobody, grafana, loki, ...) can read its bind-mounted secret.
chmod 700 "$DIR"

random_password() {
    openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-32
}

create_password() {
    local file="$DIR/$1"
    if [[ -s "$file" ]]; then
        echo "kept     $file"
        return
    fi
    # printf is a shell builtin: the password is never an argument of another process.
    printf '%s' "$(random_password)" > "$file"
    echo "created  $file"
}

create_empty() {
    local file="$DIR/$1"
    if [[ -e "$file" ]]; then
        echo "kept     $file"
        return
    fi
    : > "$file"
    echo "created  $file (empty: $2)"
}

create_default() {
    local file="$DIR/$1"
    if [[ -s "$file" ]]; then
        echo "kept     $file"
        return
    fi
    printf '%s' "$2" > "$file"
    echo "created  $file ($3)"
}

create_password grafana_admin_password
create_password grafana_metrics_password
create_password node_exporter_password
create_empty sentinel_metrics_token "set it to Sentinel's METRICS_AUTH_TOKEN to monitor Sentinel"
create_default alertmanager_webhook_url "http://alert-sink:9099/alerts" \
    "the bundled alert-sink; replace with a real receiver URL"

# Node Exporter only accepts bcrypt hashes in its web config.
web_config="$DIR/node_exporter_web.yml"
if [[ -s "$web_config" ]]; then
    echo "kept     $web_config"
else
    hash="$(tr -d '\n' < "$DIR/node_exporter_password" \
        | docker run --rm -i "$HTPASSWD_IMAGE" htpasswd -niBC 12 prometheus \
        | cut -d: -f2 | tr -d '\r\n')"
    if [[ "$hash" != \$2* ]]; then
        echo "error: could not create a bcrypt hash with $HTPASSWD_IMAGE" >&2
        exit 1
    fi
    printf 'basic_auth_users:\n  prometheus: %s\n' "$hash" > "$web_config"
    echo "created  $web_config"
fi

chmod 644 "$DIR"/*
