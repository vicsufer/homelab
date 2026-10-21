#!/bin/sh
set -eu
cd "$(dirname "$0")"

node=${1:?usage: $0 <node> [apply-config flags]}
shift
file=$(ls nodes/*/"$node".yaml)
ip=${IP:-$(yq 'select(.kind == "LinkConfig") | .addresses[0].address' "$file" | cut -d/ -f1)}

talosctl apply-config --nodes "$ip" --endpoints "$ip" --file "_out/$node.yaml" "$@"
