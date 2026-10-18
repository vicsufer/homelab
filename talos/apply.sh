#!/bin/sh
# Apply a rendered node config: ./apply.sh <node> [talosctl apply-config flags, e.g. --dry-run, --insecure]
# IP=<addr> overrides the node's `# ip:` header (e.g. a fresh node still on a DHCP address).
set -eu
cd "$(dirname "$0")"

node=${1:?usage: $0 <node> [apply-config flags]}
shift
file=$(ls nodes/*/"$node".yaml)
ip=${IP:-$(sed -n 's/^# ip: //p' "$file")}

talosctl apply-config --nodes "$ip" --endpoints "$ip" --file "_out/$node.yaml" "$@"
