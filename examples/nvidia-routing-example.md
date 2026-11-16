# 10 – NVIDIA Switchyard: content-aware model routing (worked example)

**Goal:** show Kong AI Gateway sending each request to the *right-sized* model automatically. Easy prompts go to a fast, cheap model; hard prompts go to a stronger one. The caller always sends the same request to the same URL and never chooses a model.

`POST https://ea-aigw.kong-sales-engineering.com/route/v1/messages` with `"model": "ea-claude-route"`. The gateway answers with headers that say what happened:
`X-AI-Routing-Backend: fast|strong` and `X-AI-Routing-Outcome: enforced|observed|fallback`.

## How it works
```
client ──▶ Kong /route ──▶ ai-routing-provider policy ──▶ POST /v1/decision ──▶ NVIDIA Switchyard  (route: switchyard/smart)
                                  ▲                                                   │  asks a JUDGE: "can the cheap model solve this?"
                                  │                                                   ▼
                                  │                          judge call goes back THROUGH Kong (/route, model ea-route-fast = Claude Haiku)
                                  │                                                   │  verdict p_solve  ──▶ target "fast" or "strong"
                                  └────────── Kong resolves the target name to its own AI Model and sends the request there
        fast   = ea-route-fast   (Claude Haiku 4.5)
        strong = ea-route-strong (Claude Sonnet on AWS Bedrock)
```
- Switchyard only **names** a target. Kong maps the name to a model it already trusts, so the decision service can never introduce a URL or provider.
- The judge estimates `p_solve`, the chance the cheap model completes the task. If `p_solve` is at or above the threshold (0.5, higher when unsure) the request goes to **fast**, otherwise **strong**. An unusable verdict sends it to **strong** (fail toward quality).
- The judge is itself a model call, and it goes through the gateway, so it is governed, metered and visible in the dashboards (extra `ea-route-fast` requests).
- The policy shares only the opening task and the latest user message with the judge (`prompt_disclosure: task_and_latest_user_prompt`); everything else is redacted.

## Configuration (what changed from the 50/50 random split)
| Where | Setting | Value |
|---|---|---|
| `k8s/switchyard-routes.toml` | new route `switchyard/smart` | `type = "llm_classifier"`, `mode = "capability"`, judge = `fast`, `weak_target = "fast"`, `strong_target = "strong"`, `base_threshold = 0.5`, `threshold_step = 0.1` |
| `k8s/switchyard-routes.toml` | judge client | calls the gateway at `/route` (format `anthropic_messages`), `timeout_ms = 20000`, `max_retries = 1` |
| `kong/70-routing-provider.yaml` | `decision_route` | `switchyard/smart` (was `switchyard/general`, a random 50/50 split, still available) |
| `kong/70-routing-provider.yaml` | `prompt_disclosure` | `task_and_latest_user_prompt` (was `none`, which hides the prompt from the judge) |
| `kong/70-routing-provider.yaml` | `timeout_ms` | `15000` (was `800`; the judge is an LLM call of about 1.5 to 3 s, so a short timeout falls back every time) |

## Results (real run against the live gateway, 10 requests, all HTTP 200)
| # | Prompt (type) | Routed to | Served by | Outcome | Latency | Tokens in/out |
|---|---|---|---|---|---|---|
| 1 | What is the capital of France? (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 2.2 s | 14/10 |
| 2 | Convert 72 degrees Fahrenheit to Celsius. (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 2.4 s | 19/96 |
| 3 | Give me a one-sentence definition of an API gateway. (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 1.9 s | 19/37 |
| 4 | Rewrite this politely: 'send me the report now'. (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 2.9 s | 22/129 |
| 5 | List three primary colors. (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 2.0 s | 12/56 |
| 6 | What does HTTP status 404 mean? (easy) | **fast** | claude-haiku-4-5-20251001 | enforced | 3.6 s | 16/205 |
| 7 | Design a multi-region active-active architecture for a game matchmakin… (hard) | **strong** | claude-sonnet-5-5 | enforced | 5.8 s | 71/400 |
| 8 | Write a Python asyncio rate limiter that supports per-key token bucket… (hard) | **fast** | claude-haiku-4-5-20251001 | enforced | 4.5 s | 47/400 |
| 9 | Our p99 latency doubled after moving from monolith to 40 microservices… (hard) | **strong** | claude-sonnet-5-5 | enforced | 5.3 s | 81/400 |
| 10 | Compare event sourcing with CRDT-based replication for a collaborative… (hard) | **strong** | claude-sonnet-5-5 | enforced | 5.8 s | 69/400 |

| | Easy prompts (6) | Hard prompts (4) |
|---|---|---|
| Routed to **fast** (Haiku) | 6 | 1 |
| Routed to **strong** (Sonnet) | 0 | 3 |

- **Cost** (reported token usage, Haiku 1 / 5 and Sonnet 3 / 15 USD per 1M tokens in / out): routed **$0.02348** vs **$0.03311** if everything had gone to Sonnet, a **29.1% saving** on this mix. The judge's own Haiku calls are not included (small). Responses were capped at 400 tokens, so absolute numbers are small; the percentage depends on your easy/hard mix.
- **Latency:** fast answers averaged 2.8 s and strong answers 5.6 s end to end. Routing adds the judge call (about 1.5 to 3 s) to every request, so it pays off when the strong model is much slower or pricier than the judge, not for latency-critical paths. Switchyard can cache a decision per session (`classify_trigger = "new_session"`) so only the first turn of a conversation pays it.
- **The judge is not perfect, and varies run to run.** One hard prompt (the Python asyncio rate limiter) went to Haiku because the judge judged Haiku could handle it. Raise `base_threshold` to send more traffic to strong; lower it to save more.

Sample answers: easy → "The capital of France is Paris.…" (Haiku); hard → "…" (Sonnet).

## Safety: it fails open
Real test: the decision URL was pointed at a hostname that does not exist, then restored.
```
decision service unreachable | HTTP 200 | X-AI-Routing-Backend: fast | X-AI-Routing-Outcome: fallback | served by claude-haiku-4-5-20251001
gateway log: [ai-routing-provider] {"outcome":"fallback","mode":"enforce","backend_id":"fast","reason":"decision call failed: [cosocket] DNS resolution failed ..."}
restored                     | HTTP 200 | X-AI-Routing-Backend: strong | X-AI-Routing-Outcome: enforced | served by claude-sonnet-5-5
```
If Switchyard is down, slow or returns something unusable, traffic is still served by the configured `default_target` (here **fast**; choose **strong** if quality matters more than cost) and the outcome header says `fallback`.
*A first attempt to simulate the outage by changing the Kubernetes Service selector did not work: Kong keeps a keep-alive connection to the Switchyard pod, which a selector change does not cut.*

## Run it yourself: two curls
Same URL, same `"model": "ea-claude-route"`; only the prompt changes. `KEY` is the gateway consumer key (`KONG_API_KEY_TEST` in `secrets.yaml`).
```bash
KEY=$(. scripts/env.sh; echo "$KONG_API_KEY_TEST")     # from customers/ea-poc; or paste your key
```
**Easy prompt, expect `fast` (Haiku):**
```bash
curl -si https://ea-aigw.kong-sales-engineering.com/route/v1/messages \
  -H "x-api-key: $KEY" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"ea-claude-route","max_tokens":100,"messages":[{"role":"user","content":"What is the capital of France?"}]}' \
  | grep -iE '^HTTP|^x-ai-routing|"model"' | sed -E 's/.*("model":"[^"]*").*/\1/'
```
```
HTTP/2 200
x-ai-routing-backend: fast
x-ai-routing-outcome: enforced
"model":"claude-haiku-4-5-20251001"
```
**Hard prompt, expect `strong` (Sonnet on Bedrock):**
```bash
curl -si https://ea-aigw.kong-sales-engineering.com/route/v1/messages \
  -H "x-api-key: $KEY" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"ea-claude-route","max_tokens":100,"messages":[{"role":"user","content":"Design a multi-region active-active architecture for a game matchmaking service handling 2M concurrent players. Cover consistency, failover, data residency and a migration plan with rollback criteria."}]}' \
  | grep -iE '^HTTP|^x-ai-routing|"model"' | sed -E 's/.*("model":"[^"]*").*/\1/'
```
```
HTTP/2 200
x-ai-routing-backend: strong
x-ai-routing-outcome: enforced
"model":"claude-sonnet-5-5"
```
(Those two outputs are real, captured from the live gateway.) To read the answer itself, drop the `grep`/`sed` and pipe through `jq -r '.content[0].text'` (use `curl -s` instead of `-si`, and add `-D -` if you also want the headers). The judge is a model, so a borderline prompt can route differently between runs.

Optional, if you ever want all ten prompts and the cost comparison at once: `python3 scripts/routing-demo.py`.

Useful knobs, all in `kong/70-routing-provider.yaml` unless noted: `mode: observe_only` (decisions only, outcome `observed`, nothing rerouted: the safe way to trial it on live traffic), `default_target`, and in `k8s/switchyard-routes.toml` `base_threshold` / `threshold_step`. After editing the TOML: `kubectl -n ea-aigw create configmap switchyard-routes --from-file=routes.toml=k8s/switchyard-routes.toml --dry-run=client -o yaml | kubectl apply -f -`, wait about a minute, then `kubectl -n ea-aigw exec deploy/switchyard -c switchyard -- sh -c 'kill 1'` (restarts the container, keeps the compiled binary).

## Other Switchyard route types you could show next
`stage_router` (efficient vs capable by conversation stage), `escalation` (start cheap, escalate when the judge says the work is struggling), `composite`, and `advisor`. They use the same Kong policy; only the `decision_route` and the TOML route change.
