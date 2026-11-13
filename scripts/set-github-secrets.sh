#!/usr/bin/env bash
# One-time: copy the credentials the workflows need from your local secrets file into GitHub Actions secrets (encrypted, repo-scoped).
# Run it yourself: it sends credential values to GitHub. Usage: scripts/set-github-secrets.sh /path/to/secrets.yaml
set -euo pipefail
F=${1:?path to secrets.yaml}; . "$F"
for n in EA_PAT OPENAI_KEY AZURE_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ASSUME_ROLE_ARM REDIS_PASSWORD; do
  v=${!n:?$n missing in $F}; printf '%s' "${v//\"/}" | gh secret set "$n" --repo DeclanPaulKeane/ea-automation; echo "set $n"
done
