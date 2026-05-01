#!/usr/bin/env bash
# Install dependencies and build Unimeter + loadgen on provisioned servers.
# Usage: setup.sh {nodes|loadgen|all}

source "$(dirname "$0")/config.sh"

setup_node() {
    local hostname="$1"
    local ip
    ip=$(get_public_ip "$hostname")
    log "Setting up $hostname ($ip)"

    remote_ip "$ip" bash -s "$ZIG_VERSION" "$UNIMETER_REPO" "$UNIMETER_BRANCH" <<'SCRIPT'
set -euo pipefail
ZIG_VERSION="$1"; REPO="$2"; BRANCH="$3"

if [[ -f /opt/unimeter/zig-out/bin/billing ]]; then
    echo "Already built, skipping"
    exit 0
fi

apt-get update -qq && apt-get install -y -qq git xz-utils > /dev/null

if [[ ! -f /opt/zig/zig ]]; then
    cd /tmp
    ARCH=$(uname -m)
    [[ "$ARCH" == "aarch64" ]] && ZIG_ARCH="aarch64" || ZIG_ARCH="x86_64"
    curl -sLO "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    mkdir -p /opt/zig
    tar xf "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -C /opt/zig --strip-components=1
    rm -f "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
fi
export PATH="/opt/zig:$PATH"

if [[ ! -d /opt/unimeter ]]; then
    git clone --branch "$BRANCH" --depth 1 "$REPO" /opt/unimeter
fi
cd /opt/unimeter
zig build -Doptimize=ReleaseFast

echo "Build complete: $(ls -la zig-out/bin/billing)"
SCRIPT
}

setup_loadgen() {
    local ip
    ip=$(get_public_ip "$LOADGEN")
    log "Setting up loadgen ($ip)"

    scp $SSH_OPTS -r "$INFRA_DIR/../loadgen" "root@$ip:/opt/loadgen"

    remote_ip "$ip" bash <<'SCRIPT'
set -euo pipefail

if [[ ! -f /usr/local/go/bin/go ]]; then
    ARCH=$(uname -m)
    [[ "$ARCH" == "aarch64" ]] && GO_ARCH="arm64" || GO_ARCH="amd64"
    curl -sL "https://go.dev/dl/go1.24.2.linux-${GO_ARCH}.tar.gz" | tar xz -C /usr/local
fi
export PATH="/usr/local/go/bin:$PATH"

cd /opt/loadgen
go build -o loadgen .

echo "Loadgen built: $(ls -la loadgen)"
SCRIPT
}

case "${1:-all}" in
    nodes)
        for name in "${NODES[@]}"; do setup_node "$name"; done
        ;;
    loadgen)
        setup_loadgen
        ;;
    all)
        for name in "${NODES[@]}"; do setup_node "$name"; done
        setup_loadgen
        ;;
    *) echo "Usage: $0 {nodes|loadgen|all}" ;;
esac
