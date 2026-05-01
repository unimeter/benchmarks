#!/usr/bin/env bash
# Start, stop, and manage the Unimeter cluster on provisioned servers.
# Usage: cluster.sh {start|stop|restart|ssh [hostname]}

source "$(dirname "$0")/config.sh"

cmd_start() {
    log "Starting ${#NODES[@]}-node cluster (private network)"

    local pub_ips=() priv_ips=()
    for name in "${NODES[@]}"; do
        pub_ips+=("$(get_public_ip "$name")")
        priv_ips+=("$(get_private_ip "$name")")
    done

    local n=${#NODES[@]}
    for ((i=0; i<n; i++)); do
        local ssh_ip="${pub_ips[$i]}"
        local bind_ip="${priv_ips[$i]}"
        local peers=""
        if [[ $n -gt 1 ]]; then
            for ((j=0; j<n; j++)); do
                [[ $j -eq $i ]] && continue
                [[ -n "$peers" ]] && peers+=","
                peers+="${j}:${priv_ips[$j]}:${PEER_PORT}"
            done
        fi

        log "  node $i: bind=$bind_ip peers=$peers"
        remote_ip "$ssh_ip" bash <<SCRIPT
set -euo pipefail
NODE_ID="$i"
BIND_IP="$bind_ip"
PEERS="$peers"
PORT="$INGEST_PORT"
HTTP_PORT="$HTTP_PORT"

pkill -f "billing --node-id" || true
sleep 1

mkdir -p /var/lib/unimeter
cd /opt/unimeter

PEERS_FLAG=""
[[ -n "\$PEERS" ]] && PEERS_FLAG="--peers=\$PEERS"

export MY_ADDR="\$BIND_IP:\$PORT"
export SYNC_GROUP_DELAY_US="${SYNC_GROUP_DELAY_US:-0}"

nohup ./zig-out/bin/billing \\
    --node-id="\$NODE_ID" \\
    --port="\$PORT" \\
    --http-port="\$HTTP_PORT" \\
    --data-dir=/var/lib/unimeter \\
    \$PEERS_FLAG \\
    > /var/log/unimeter.log 2>&1 &

sleep 2
if pgrep -f "billing --node-id" > /dev/null; then
    echo "Node \$NODE_ID running (pid \$(pgrep -f 'billing --node-id'))"
else
    echo "FAILED to start node \$NODE_ID"
    tail -20 /var/log/unimeter.log
    exit 1
fi
SCRIPT
    done

    log "Waiting 5s for leader election..."
    sleep 5
    log "Cluster ready"
}

cmd_stop() {
    log "Stopping cluster"
    for name in "${NODES[@]}"; do
        remote "$name" "pkill -f 'billing --node-id' || true" 2>/dev/null || true
    done
}

cmd_ssh() {
    local target="${1:-$LOADGEN}"
    local ip
    ip=$(get_public_ip "$target")
    exec ssh $SSH_OPTS "root@$ip"
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 2; cmd_start ;;
    ssh)     cmd_ssh "${2:-}" ;;
    *)       echo "Usage: $0 {start|stop|restart|ssh [hostname]}" ;;
esac
