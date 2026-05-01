#!/usr/bin/env bash
# Create and destroy Cherry Servers bare-metal instances.
# Usage: provision.sh {up|down|status|plans}

source "$(dirname "$0")/config.sh"

wait_deployed() {
    local server_id="$1" hostname="$2"
    for _ in $(seq 1 60); do
        local status
        status=$(get_server_status "$server_id")
        case "$status" in
            deployed) return 0 ;;
            failed|terminating) die "$hostname status: $status" ;;
            *) printf "." ;;   # pending, provisioning, deploying, ready, unknown, etc.
        esac
        sleep 30
    done
    die "Timeout waiting for $hostname"
}

wait_ssh() {
    local ip="$1"
    for _ in $(seq 1 30); do
        ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" true 2>/dev/null && return 0
        sleep 10
    done
    die "SSH timeout for $ip"
}

cmd_up() {
    local ssh_key_id
    ssh_key_id=$(get_ssh_key_id)
    log "Creating ${#HOSTNAMES[@]} servers (plan=$PLAN, region=$REGION, billing=$BILLING_CYCLE)"

    for hostname in "${HOSTNAMES[@]}"; do
        local existing_id
        existing_id=$(get_server_id "$hostname" 2>/dev/null) || true
        if [[ -n "$existing_id" ]]; then
            local status
            status=$(get_server_status "$existing_id" 2>/dev/null) || true
            if [[ "$status" == "deployed" ]]; then
                log "  $hostname already exists (id=$existing_id), skipping"
                continue
            fi
        fi

        log "  Creating $hostname..."
        local resp
        resp=$(cherry_api POST "/projects/$CHERRY_PROJECT_ID/servers" \
            -d "{
                \"plan\": \"$PLAN\",
                \"region\": \"$REGION\",
                \"hostname\": \"$hostname\",
                \"image\": \"$IMAGE\",
                \"billing_cycle\": \"$BILLING_CYCLE\",
                \"ssh_keys\": [$ssh_key_id]
            }")

        local server_id
        server_id=$(echo "$resp" | jq -r '.id // empty')
        [[ -n "$server_id" ]] || die "Failed to create $hostname: $resp"
        save_server_id "$hostname" "$server_id"
        log "  $hostname created (id=$server_id)"
    done

    log "Waiting for deploy (bare metal ~5-15 min)..."
    for hostname in "${HOSTNAMES[@]}"; do
        local server_id
        server_id=$(get_server_id "$hostname")
        printf "  $hostname"
        wait_deployed "$server_id" "$hostname"
        echo " deployed ($(get_public_ip "$hostname"))"
    done

    log "Waiting for SSH..."
    for hostname in "${HOSTNAMES[@]}"; do
        local ip
        ip=$(get_public_ip "$hostname")
        wait_ssh "$ip"
        log "  $hostname ($ip) ready"
    done
}

cmd_down() {
    log "Destroying all benchmark servers"
    for hostname in "${HOSTNAMES[@]}"; do
        local server_id
        server_id=$(get_server_id "$hostname" 2>/dev/null) || true
        if [[ -z "$server_id" ]]; then
            log "  $hostname: not in state file, skipping"
            continue
        fi
        cherry_api DELETE "/servers/$server_id" > /dev/null
        log "  $hostname (id=$server_id) deleted"
    done
    rm -f "$STATE_FILE"
}

cmd_status() {
    for hostname in "${HOSTNAMES[@]}"; do
        local server_id pub priv status
        server_id=$(get_server_id "$hostname" 2>/dev/null) || { echo "$hostname: not provisioned"; continue; }
        status=$(get_server_status "$server_id" 2>/dev/null) || status="unknown"
        pub=$(get_public_ip "$hostname" 2>/dev/null) || pub="n/a"
        priv=$(get_private_ip "$hostname" 2>/dev/null) || priv="n/a"
        printf "%-16s  pub=%-15s  priv=%-15s  %s\n" "$hostname" "$pub" "$priv" "$status"
    done
}

cmd_plans() {
    log "Available bare-metal plans in $REGION:"
    cherry_api GET "/teams/$CHERRY_TEAM_ID/plans?region=$REGION" \
        | jq -r '.[] | select(.type == "baremetal") | "\(.slug)\t\(.name)\t$\(.pricing.price)/hr"' \
        | column -t -s $'\t'
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    plans)  cmd_plans ;;
    *)      echo "Usage: $0 {up|down|status|plans}" ;;
esac
