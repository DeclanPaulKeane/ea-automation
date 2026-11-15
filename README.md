# ea-automation

GitOps for the EA AI Gateway POC. **Everything here manages one gateway only: `kong-team-example-gateway`** (Konnect, US).
Config is [kongctl](https://github.com/Kong/kongctl) declarative YAML in namespace `ea-automation`; nothing here ever deletes (plans use `--mode apply`; `kongctl apply` never deletes what the files do not declare).

```
kong/00-gateway.yaml       the gateway (already exists; adopted into the namespace)
kong/10-providers.yaml     OpenAI, Azure OpenAI, Bedrock providers (credentials come from the environment, never from git)
kong/20-policies.yaml      global OTEL + Prometheus + correlation-id
kong/30-mcp.yaml           Atlassian (Jira/Confluence) MCP, OIDC introspection
kong/35-mcp-github.yaml    GitHub MCP, OIDC introspection via an in-cluster adapter (deploy/github-introspect-*)
kong/40-agents.yaml        triage-agent <-> release-agent (A2A)
kong/50-policy-rag.yaml    RAG injector policy
kong/60-custom-policy.yaml custom policy (ea-stamp) + Lua in kong/lua/
kong/models/*.yaml         ONE FILE PER MODEL, each on its own path: POST https://ea-aigw.kong-sales-engineering.com/<path>/v1/messages
kong/70-routing-provider.yaml  AI Routing Provider (NVIDIA Switchyard) + entry model + two routing targets, all on /route
deploy/                    Switchyard decision service manifest + routes (compiled in-cluster from crates.io; see docs)
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
## More examples (all `POST https://ea-aigw.kong-sales-engineering.com/<path>/v1/messages`, header `x-api-key: $KEY`)
| Path | `model` | Shows |
|---|---|---|
| `/openai` `/azure` `/bedrock` | `ea-openai-gpt` `ea-azure-gpt4o` `ea-bedrock-claude` | one model per provider, Anthropic format in and out |
| `/rag` | `ea-claude-rag` | RAG injector: ask "Which days can Game Platform releases ship?" |
| `/custom` | `ea-claude-custom` | custom policy: response carries `X-EA-Policy: stamped-by-ea-gateway` |
| `/route` | `ea-claude-route` | AI Routing Provider: `X-AI-Routing-Backend: fast\|strong` and `X-AI-Routing-Outcome: enforced`; strong is served by Sonnet on Bedrock, fast by Haiku |
| `/a2a/triage` | (A2A JSON-RPC `message/send`) | triage-agent calls release-agent through the gateway |
| `/atlassian` `/github` | (MCP client, e.g. Insomnia) | OAuth login in the client; Kong validates the token with an OIDC strategy and forwards it |

```bash
# routing: run it a few times and watch the backend header flip between fast and strong
for i in 1 2 3 4; do curl -si https://ea-aigw.kong-sales-engineering.com/route/v1/messages -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"model":"ea-claude-route","max_tokens":30,"messages":[{"role":"user","content":"Reply with one word: ok"}]}' | grep -i x-ai-routing; done
```
Flip the policy between `mode: observe_only` (decisions only, outcome `observed`) and `mode: enforce` in `kong/70-routing-provider.yaml`; the PR plan shows the one-line diff.

Rules the gateway enforces: one **distinct path** per model (overlapping paths return 503), and the request body `model` must equal the model `name`.

## One-time setup
**No credentials are sent to GitHub.** Run kongctl locally with your env loaded:
```bash
set -a; . /path/to/secrets.yaml; set +a
export KONGCTL_DEFAULT_KONNECT_PAT=$EA_PAT OPENAI_BEARER="Bearer $OPENAI_KEY" REDIS_PASSWORD_CLEAN=${REDIS_PASSWORD//\"/} \
  ATLASSIAN_CACHE_SALT=ea-poc-atlassian-cache-v1 INTROSPECT_CLIENT_SECRET=unused \
  ATLASSIAN_PUBLIC_MCP_URL=https://ea-aigw.kong-sales-engineering.com/atlassian GITHUB_PUBLIC_MCP_URL=https://ea-aigw.kong-sales-engineering.com/github
kongctl plan -f kong --recursive --mode apply     # review
kongctl apply -f kong --recursive --auto-approve
```
`scripts/set-github-secrets.sh` exists only if you later choose to run the workflows; the workflows are optional.

## Workflows
- `plan.yml`: on pull requests touching `kong/**`, runs `kongctl plan --mode apply` and posts the changes to the job summary.
- `apply.yml`: on merge to `main` (or manually), runs `kongctl apply`, then lists the models.
