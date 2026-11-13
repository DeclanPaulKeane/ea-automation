#!/usr/bin/env bash
# Scaffold a new model file. Usage: scripts/new-model.sh <name> <path> <provider> <target-model> [provider-type]
# Example: scripts/new-model.sh ea-claude-sonnet /sonnet kong-se-anthropic claude-sonnet-5-5 anthropic
# Then: git checkout -b add-<name> && git add kong/models && git commit && git push, and open a PR. The PR shows the plan; merging applies it.
set -euo pipefail
NAME=${1:?name} PATH_=${2:?path starting with /} PROVIDER=${3:?provider name} TARGET=${4:?target model} PTYPE=${5:-anthropic}
cd "$(dirname "$0")/.."
F=kong/models/${NAME#ea-}.yaml
[ ! -e "$F" ] || { echo "$F exists"; exit 1; }
cat > "$F" <<YAML
# $NAME -> POST https://ea-aigw.kong-sales-engineering.com$PATH_/v1/messages
_defaults:
  kongctl:
    namespace: ea-automation

ai_gateway_models:
- ref: $NAME
  ai_gateway: ea-gw
  name: $NAME
  display_name: "$NAME"
  type: model
  enabled: true
  formats: [{type: anthropic}]
  capabilities: ['*']
  labels: {owner: ea-poc, purpose: ${NAME#ea-}}
  access: {auth_strategies: [key-auth]}
  config:
    route: {paths: [$PATH_], protocols: [http, https], strip_path: true}
    model: {name_header: true}
    logging: {payloads: false}
  targets:
  - name: $TARGET
    provider: $PROVIDER
    weight: 100
    config: {type: $PTYPE}
YAML
echo "created $F. Review it (add input_cost/output_cost per million tokens), then commit on a branch and open a PR."
