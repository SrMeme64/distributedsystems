#!/bin/sh
# Runs keepalived and keeps it bound to the current network interface.
#
# Docker Desktop can rename the container veth (eth0 -> vethXXXX) when it
# restarts. Keepalived keeps the old name, enters FAULT and the VIP disappears.
# This wrapper detects the interface by its expected IP, renders the config
# with the current name and restarts keepalived when the name changes.
set -eu

template="/etc/keepalived/keepalived.conf.template"
config="/etc/keepalived/keepalived.conf"
expected_ip="$(sed -n 's/^[[:space:]]*unicast_src_ip[[:space:]][[:space:]]*\([0-9.]*\).*/\1/p' "$template" | head -n1)"

detect_interface() {
    if [ -n "$expected_ip" ]; then
        detected="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$expected_ip" '$4 ~ ("^" ip "/") {print $2; exit}')"
        if [ -n "$detected" ]; then
            printf '%s' "$detected"
            return 0
        fi
        return 1
    fi

    detected="$(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2; exit}')"
    printf '%s' "${detected:-eth0}"
}

render_config() {
    sed "s/eth0/$1/g" "$template" > "$config"
}

keepalived_pid=""
misses=0
max_misses=30

cleanup() {
    if [ -n "$keepalived_pid" ] && kill -0 "$keepalived_pid" 2>/dev/null; then
        kill "$keepalived_pid" 2>/dev/null || true
        wait "$keepalived_pid" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup TERM INT

while true; do
    if ! iface="$(detect_interface)"; then
        misses=$((misses + 1))
        echo "keepalived-entrypoint: waiting for an interface with ${expected_ip} (${misses}/${max_misses})"
        if [ "$misses" -ge "$max_misses" ]; then
            # The shared network namespace (network_mode: service:<lb>) can be
            # left empty when the LB container was recreated while this sidecar
            # kept the old namespace. Exiting lets Docker recreate the sidecar
            # and re-attach it to the current namespace.
            echo "keepalived-entrypoint: no interface after $((max_misses * 2))s; exiting so the container is recreated"
            exit 1
        fi
        sleep 2
        continue
    fi
    misses=0

    render_config "$iface"
    echo "keepalived-entrypoint: using interface ${iface} (ip ${expected_ip})"
    rm -f /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid /run/keepalived/checkers.pid
    keepalived --dont-fork --log-console --use-file="$config" &
    keepalived_pid=$!

    while kill -0 "$keepalived_pid" 2>/dev/null; do
        if ! current="$(detect_interface)"; then
            current=""
        fi
        if [ "$current" != "$iface" ]; then
            echo "keepalived-entrypoint: interface changed from '${iface}' to '${current}'; restarting"
            kill "$keepalived_pid" 2>/dev/null || true
            wait "$keepalived_pid" 2>/dev/null || true
            break
        fi
        sleep 2
    done

    sleep 1
done
