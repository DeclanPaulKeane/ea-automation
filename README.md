# ea-automation

GitOps for the EA AI Gateway POC. **Everything here manages one gateway only: `kong-team-example-gateway`** (Konnect, US).
Config is [kongctl](https://github.com/Kong/kongctl) declarative YAML in namespace `ea-automation`; nothing here ever deletes (`--mode apply`).

```
kong/00-gateway.yaml       the gateway (already exists; adopted into the namespace)
kong/10-providers.yaml     OpenAI, Azure OpenAI, Bedrock providers (credentials come from the environment, never from git)
kong/20-policies.yaml      global OTEL + Prometheus + correlation-id
kong/30-mcp.yaml           Jira + GitHub MCP passthrough
kong/40-agents.yaml        triage-agent <-> release-agent (A2A)
kong/50-policy-rag.yaml    RAG injector policy
kong/60-custom-policy.yaml custom policy (ea-stamp) + Lua in kong/lua/
kong/models/*.yaml         ONE FILE PER MODEL, each on its own path: POST https://ea-aigw.kong-sales-engineering.com/<path>/v1/messages
pending/                   staged routing-provider (needs the Switchyard decision service)
```

## Add a model (the demo)
```bash
scripts/new-model.sh ea-claude-sonnet /sonnet kong-se-anthropic claude-sonnet-5-5 anthropic
git checkout -b add-claude-sonnet && git add kong/models && git commit -m "Add Claude Sonnet model" && git push -u origin HEAD
gh pr create --fill          # the Plan workflow comments the diff: 1 model to create
gh pr merge --squash         # the Apply workflow creates it on the gateway
curl https://ea-aigw.kong-sales-engineering.com/sonnet/v1/messages -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"model":"ea-claude-sonnet","max_tokens":50,"messages":[{"role":"user","content":"hello"}]}'
```
Rules the gateway enforces: one **distinct path** per model (overlapping paths return 503), and the request body `model` must equal the model `name`.

## One-time setup
`scripts/set-github-secrets.sh /path/to/secrets.yaml` (run it yourself) stores `EA_PAT`, `OPENAI_KEY`, `AZURE_KEY`, `AWS_*`, `REDIS_PASSWORD` as Actions secrets.

## Workflows
- `plan.yml`: on pull requests touching `kong/**`, runs `kongctl plan --mode apply` and posts the changes to the job summary.
- `apply.yml`: on merge to `main` (or manually), runs `kongctl apply --mode apply`, then lists the models.
