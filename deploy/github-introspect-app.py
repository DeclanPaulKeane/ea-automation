"""RFC 7662 token-introspection adapter for GitHub OAuth app tokens (stdlib only).
GitHub has no standard introspection endpoint, and its tokens are opaque (gho_...), so Kong's openid-connect auth strategy cannot validate them on its own.
Kong POSTs `token=<access token>` here; we ask GitHub's check-token API (POST /applications/{client_id}/token, authenticated with the OAuth app's
client id + secret) and translate the answer to {"active": true|false, ...}. The client secret lives only in the cluster (Secret github-oauth).
  POST /introspect                          -> RFC 7662 response
  GET  /.well-known/openid-configuration    -> minimal discovery document (the strategy's `issuer` points here)
  GET  /jwks                                -> empty key set
  GET  /health"""
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CID, SEC = os.environ["GITHUB_CLIENT_ID"], os.environ["GITHUB_CLIENT_SECRET"]
SELF = os.environ.get("SELF_URL", "http://github-introspect.ea-aigw.svc.cluster.local")
AUTH = "Basic " + base64.b64encode(f"{CID}:{SEC}".encode()).decode()

def check(token):
    req = urllib.request.Request(f"https://api.github.com/applications/{CID}/token", json.dumps({"access_token": token}).encode(), method="POST",
        headers={"Authorization": AUTH, "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ea-github-introspect"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r: d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in (404, 422): return {"active": False}          # unknown / revoked / belongs to another app
        raise
    u = d.get("user") or {}
    out = {"active": True, "sub": str(u.get("id", "")), "username": u.get("login", ""), "client_id": CID, "token_type": "bearer",
           "scope": " ".join(d.get("scopes") or []), "iss": "https://github.com/login/oauth"}
    if d.get("expires_at"): out["exp"] = None                      # GitHub OAuth app tokens do not expire by default; omit
    return {k: v for k, v in out.items() if v is not None}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/.well-known/openid-configuration"):
            return self.send(200, {"issuer": SELF, "authorization_endpoint": "https://github.com/login/oauth/authorize", "token_endpoint": "https://github.com/login/oauth/access_token",
                                   "introspection_endpoint": SELF + "/introspect", "jwks_uri": SELF + "/jwks", "response_types_supported": ["code"],
                                   "grant_types_supported": ["authorization_code"], "code_challenge_methods_supported": ["S256"]})
        if self.path.startswith("/jwks"): return self.send(200, {"keys": []})
        self.send(200, {"ok": True})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        token = (urllib.parse.parse_qs(raw).get("token") or [""])[0] if "json" not in (self.headers.get("Content-Type") or "") else (json.loads(raw or "{}").get("token") or "")
        if not token: return self.send(400, {"error": "invalid_request"})
        try:
            res = check(token); print(f"introspect active={res.get('active')} user={res.get('username','-')} scope={res.get('scope','-')}", file=sys.stderr, flush=True); self.send(200, res)
        except Exception as e:
            print(f"introspect error: {str(e)[:120]}", file=sys.stderr, flush=True); self.send(503, {"error": "temporarily_unavailable", "detail": str(e)[:120]})

ThreadingHTTPServer(("", 8080), H).serve_forever()
