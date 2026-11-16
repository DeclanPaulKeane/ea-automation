#!/usr/bin/env python3
"""NVIDIA Switchyard routing demo: send easy and hard prompts through https://<gateway>/route/v1/messages and show which model served each.
Usage: scripts/routing-demo.py [--md out.md] [--json out.json]      (reads KONG_API_KEY_TEST from secrets.yaml via the environment: run `. scripts/env.sh` first)
Prices are USD per 1M tokens (Haiku 4.5: 1 in / 5 out; Sonnet: 3 / 15) and are used only for the cost comparison."""
import json, os, sys, time, urllib.request, urllib.error
BASE = os.environ.get("ROUTE_URL", "https://ea-aigw.kong-sales-engineering.com/route/v1/messages")
KEY = os.environ["KONG_API_KEY_TEST"].strip('"')
PRICE = {"fast": (1, 5), "strong": (3, 15)}
PROMPTS = [
 ("easy", "What is the capital of France?"),
 ("easy", "Convert 72 degrees Fahrenheit to Celsius."),
 ("easy", "Give me a one-sentence definition of an API gateway."),
 ("easy", "Rewrite this politely: 'send me the report now'."),
 ("easy", "List three primary colors."),
 ("easy", "What does HTTP status 404 mean?"),
 ("hard", "Design a multi-region active-active architecture for a game matchmaking service handling 2M concurrent players. Cover the consistency model, failover, data residency, and a migration plan with rollback criteria."),
 ("hard", "Write a Python asyncio rate limiter that supports per-key token buckets, burst, distributed coordination through Redis Lua scripts, and graceful degradation when Redis is down, with tests."),
 ("hard", "Our p99 latency doubled after moving from monolith to 40 microservices. Propose a rigorous diagnosis plan using distributed traces, with hypotheses ranked by likelihood and the experiments that would falsify each."),
 ("hard", "Compare event sourcing with CRDT-based replication for a collaborative inventory system. Analyse conflict semantics, storage growth, GDPR erasure, and recommend one with justification."),
]
def call(prompt):
    body = json.dumps({"model": "ea-claude-route", "max_tokens": 400, "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(BASE, body, {"x-api-key": KEY, "content-type": "application/json", "anthropic-version": "2023-06-01"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as r: h = {k.lower(): v for k, v in r.headers.items()}; d = json.loads(r.read()); code = r.status
    except urllib.error.HTTPError as e: return {"status": e.code, "error": e.read().decode()[:120], "secs": round(time.time() - t, 1)}
    u = d.get("usage", {})
    return {"status": code, "backend": h.get("x-ai-routing-backend"), "outcome": h.get("x-ai-routing-outcome"), "model": d.get("model"), "in": u.get("input_tokens", 0),
            "out": u.get("output_tokens", 0), "secs": round(time.time() - t, 1), "answer": (d.get("content") or [{}])[0].get("text", "")[:110].replace("\n", " ")}
rows = []
for kind, p in PROMPTS:
    r = call(p); r.update(kind=kind, prompt=p); rows.append(r)
    print(f"{kind:4} -> {str(r.get('backend')):6} {str(r.get('model')):28} {r['secs']:>5}s  {p[:60]}", flush=True)
ok = [r for r in rows if r["status"] == 200 and r.get("backend")]
def cost(r, tier): i, o = PRICE[tier]; return (r["in"] * i + r["out"] * o) / 1e6
routed = sum(cost(r, r["backend"]) for r in ok); allstrong = sum(cost(r, "strong") for r in ok)
by = {k: {t: sum(1 for r in ok if r["kind"] == k and r["backend"] == t) for t in ("fast", "strong")} for k in ("easy", "hard")}
summary = {"requests": len(rows), "ok": len(ok), "routing": by, "cost_routed_usd": round(routed, 5), "cost_all_strong_usd": round(allstrong, 5),
           "saving_pct": round(100 * (1 - routed / allstrong), 1) if allstrong else 0, "avg_secs_fast": round(sum(r["secs"] for r in ok if r["backend"] == "fast") / max(1, sum(1 for r in ok if r["backend"] == "fast")), 1),
           "avg_secs_strong": round(sum(r["secs"] for r in ok if r["backend"] == "strong") / max(1, sum(1 for r in ok if r["backend"] == "strong")), 1)}
print(json.dumps(summary))
if "--json" in sys.argv: json.dump({"summary": summary, "rows": rows}, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)
if "--md" in sys.argv:
    L = ["| # | Prompt (type) | Routed to | Served by | Outcome | Latency | Tokens in/out |", "|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1): L.append(f"| {i} | {r['prompt'][:70].replace('|','/')}{'…' if len(r['prompt'])>70 else ''} ({r['kind']}) | **{r.get('backend')}** | {r.get('model')} | {r.get('outcome')} | {r['secs']} s | {r.get('in')}/{r.get('out')} |")
    open(sys.argv[sys.argv.index("--md") + 1], "w").write("\n".join(L) + "\n")
