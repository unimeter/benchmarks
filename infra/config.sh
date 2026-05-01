#!/usr/bin/env bash
# Shared configuration and helpers for benchmark infrastructure.
# Sourced by all infra scripts — never run directly.

set -euo pipefail

# Load .env if present
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

CHERRY_API="https://api.cherryservers.com/v1"
CHERRY_TOKEN="${CHERRY_TOKEN:?CHERRY_TOKEN not set}"
CHERRY_TEAM_ID="${CHERRY_TEAM_ID:?CHERRY_TEAM_ID not set}"
CHERRY_PROJECT_ID="${CHERRY_PROJECT_ID:?CHERRY_PROJECT_ID not set}"

PLAN="${PLAN:-amd-ryzen-7700x}"
REGION="${REGION:-US-Chicago}"
IMAGE="${IMAGE:-ubuntu_22_04}"
BILLING_CYCLE="hourly"
SSH_KEY_LABEL="${SSH_KEY_LABEL:-bench}"

ZIG_VERSION="0.16.0"
UNIMETER_REPO="${UNIMETER_REPO:-https://github.com/unimeter/unimeter.git}"
UNIMETER_BRANCH="${UNIMETER_BRANCH:-main}"

CLUSTER_SIZE="${CLUSTER_SIZE:-3}"
NODES=()
for i in $(seq 0 $((CLUSTER_SIZE - 1))); do
    NODES+=("bench-node-$i")
done
LOADGEN="bench-loadgen"
HOSTNAMES=("${NODES[@]}" "$LOADGEN")

INGEST_PORT=7001
PEER_PORT=8001
HTTP_PORT=9090

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$INFRA_DIR/.servers.json"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/0x180db}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

cherry_api() {
    local method="$1" path="$2"
    shift 2
    curl -s -X "$method" \
        -H "Authorization: Bearer $CHERRY_TOKEN" \
        -H "Content-Type: application/json" \
        "$CHERRY_API$path" "$@"
}

get_ssh_key_id() {
    local key_id
    key_id=$(cherry_api GET "/ssh-keys" \
        | jq -r ".[] | select(.label == \"$SSH_KEY_LABEL\") | .id" | head -1)
    [[ -n "$key_id" ]] || die "SSH key '$SSH_KEY_LABEL' not found in Cherry Servers portal"
    echo "$key_id"
}

save_server_id() {
    local hostname="$1" server_id="$2"
    if [[ -f "$STATE_FILE" ]]; then
        jq --arg h "$hostname" --arg id "$server_id" '.[$h] = $id' "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
        echo "{\"$hostname\": \"$server_id\"}" > "$STATE_FILE"
    fi
}

get_server_id() {
    local hostname="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    jq -r --arg h "$hostname" '.[$h] // empty' "$STATE_FILE"
}

_server_json() {
    local server_id="$1"
    cherry_api GET "/servers/$server_id"
}

get_server_status() {
    local server_id="$1"
    _server_json "$server_id" | jq -r '.status'
}

get_public_ip() {
    local hostname="$1"
    local server_id
    server_id=$(get_server_id "$hostname") || die "$hostname not in state file"
    _server_json "$server_id" \
        | jq -r '.ip_addresses[] | select(.address_family == 4 and .type == "primary-ip") | .address'
}

get_private_ip() {
    local hostname="$1"
    local server_id
    server_id=$(get_server_id "$hostname") || die "$hostname not in state file"
    _server_json "$server_id" \
        | jq -r '.ip_addresses[] | select(.address_family == 4 and .type == "private-ip") | .address'
}

remote() {
    local hostname="$1"; shift
    local ip
    ip=$(get_public_ip "$hostname")
    ssh $SSH_OPTS "root@$ip" "$@"
}

remote_ip() {
    local ip="$1"; shift
    ssh $SSH_OPTS "root@$ip" "$@"
}
