-- Copyright 2024-2026 Kong Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- ai-routing-provider
--
-- Calls out to a routing-decision service, validates the answer against
-- Kong-owned targets, and dispatches through Kong's own machinery.
--
-- One capability is off unless configured, so the default behaviour is a plain
-- decision-API client:
--   session_from_prompt  derive a session key when the caller cannot send one
--
-- SAFETY PROPERTY (do not weaken):
--   A decision may only select among targets already present in `conf.targets`.
--   The decision service returns `selected.target`; we look it up locally. A
--   name we do not recognise is a failed decision, not an instruction to build
--   a URL. In particular `selected.llm_client.base_url` is read for drift
--   checking only -- nothing from the decision response ever reaches the
--   network layer.
local http  = require "resty.http"
local cjson = require "cjson.safe"
local kong = kong
local AiRoutingProvider = {
  -- Must run after ai-model-selector so the model alias we set is forcefully
  -- replaced by what we read here. ai-model-selector is 957 (in September 2026).
  PRIORITY = 956,
  VERSION  = "0.1.0",
}
local OUTCOME_ENFORCED = "enforced"
local OUTCOME_OBSERVED = "observed"
local OUTCOME_FALLBACK = "fallback"
local function log_decision(entry)
  -- Structured single line: greppable in tests, parseable by a log sink.
  --
  -- A fallback means a routing decision was unusable -- the service was down,
  -- or it named a target this route is not allowed to use. Traffic is still
  -- served, so it is not an error, but it is the line an operator needs to see
  -- without turning the log level up. Everything else is routine.
  -- Kong already tags the line with the plugin name, so the payload is just
  -- the JSON.
  local line = cjson.encode(entry)
  if entry.outcome == OUTCOME_FALLBACK then
    kong.log.warn(line)
  else
    kong.log.info(line)
  end
end
-- Session correlation headers read by the decision service.
-- Source: crates/protocol/src/metadata.rs on upstream main.
local HEADER_SESSION_ID = "x-switchyard-session-id"
local HEADER_REQUEST_ID = "x-switchyard-request-id"
-- Harness session headers Switchyard resolves when x-switchyard-session-id is
-- absent, in its precedence order (HEADER_CONFIG in metadata.rs). The plugin
-- always sends x-switchyard-session-id, and that header wins upstream, so the
-- plugin has to resolve these itself: a synthesized value would otherwise
-- override the session a coding harness already sent. Codex's session id sits
-- inside the x-codex-turn-metadata JSON value and is read separately.
local HARNESS_SESSION_HEADERS_BEFORE_CODEX = {
  "x-claude-code-session-id",
  "x-nemo-relay-session-id",
  "x-session-id",
}
local HEADER_CODEX_TURN_METADATA = "x-codex-turn-metadata"
local HARNESS_SESSION_HEADER_AFTER_CODEX = "session-id"
-- Request-id aliases Switchyard falls back to after x-switchyard-request-id.
local HARNESS_REQUEST_ID_HEADERS = {
  "x-request-id",
  "x-client-request-id",
}
-- Forwarded subagent and harness correlation headers.
-- These allow Switchyard's subagent, escalation, and session affinity routers
-- to observe delegated sub-agents and turn lineage.
local FORWARD_CORRELATION_HEADERS = {
  "x-switchyard-agent-id",
  "x-switchyard-parent-agent-id",
  "x-switchyard-is-subagent",
  "x-switchyard-agent-kind",
  "x-switchyard-agent-role",
  "x-switchyard-task-id",
  "x-switchyard-task-kind",
  "x-switchyard-turn-id",
  "x-switchyard-session-final",
  "x-openai-subagent",
  "x-claude-code-session-id",
  "x-claude-code-agent-id",
  "x-claude-code-parent-agent-id",
  "x-codex-turn-metadata",
  "x-codex-parent-thread-id",
  "x-nemo-relay-session-id",
  "x-nemo-relay-subagent-id",
  "x-dynamo-session-id",
  "x-dynamo-parent-session-id",
  "x-dynamo-session-final",
  "thread-id",
  "x-task-id",
  -- Switchyard reads the harness build from User-Agent to tell whether a
  -- Claude Code client can identify its sub-agents at all.
  "user-agent",
}
-- Messages sent verbatim under recent_message_window. Not configurable: a wider
-- window is more prompt content leaving Kong, so it is a code change, not a
-- knob.
local RECENT_WINDOW = 4
-- Trailing messages sent verbatim under task_and_recent_window. Equals the
-- default `recent_turn_window` of Switchyard's escalation judge (28,
-- EscalationJudgeConfig in crates/libsy/src/algorithms/util/escalation.rs),
-- which the demo's kong-escalation route also sets explicitly. A route that
-- widens its window past this sees redaction markers at the old end.
local TASK_WINDOW = 28
-- Fields of a kept message that carry tool traffic. A trajectory judge reads
-- the tool call an assistant made as well as the result it got back.
local TOOL_FIELDS = { "tool_calls", "tool_call_id", "name" }
-- `POST /v1/decision` takes a whole provider request -- there is no server-side
-- "send me a summary instead" mode. Disclosure is therefore enforced here, by
-- deciding what Kong is willing to put in that request in the first place.
--
-- Redaction preserves the shape the routing algorithms actually read -- message
-- count, role order, and per-message size -- while replacing the text. A
-- redacted turn still gives a stage router its turn depth; it gives a prompt
-- classifier an indication of size; it gives the decision service zero
-- bytes of customer text.
--
-- Returns a marker of the form "[redacted <N> chars]".
local function redact(content)
  local len = 0
  if type(content) == "string" then
    len = #content
  elseif type(content) == "table" then
    -- Content-part array (multimodal / tools). Sum text parts, count others.
    for _, part in ipairs(content) do
      if type(part) == "table" and type(part.text) == "string" then
        len = len + #part.text
      else
        len = len + 64 -- generic estimate for non-text parts
      end
    end
  end
  return string.format("[redacted %d chars]", len)
end
-- A redacted message, still well-formed for a provider. Escalation and advisor
-- routes replay the conversation to the weak model while deciding, and
-- Switchyard's client rejects a `tool` message without `tool_call_id` (HTTP 400
-- from /v1/decision). So structure survives redaction: the tool-call ID, which
-- is an opaque correlation token, and one placeholder call per original call.
-- The tool name and arguments are content and do not leave Kong; the
-- arguments keep their size, like message text does.
local function redact_message(msg)
  local out = { role = msg.role, content = redact(msg.content) }
  if type(msg.tool_call_id) == "string" then
    out.tool_call_id = msg.tool_call_id
  end
  if type(msg.tool_calls) == "table" then
    local calls = {}
    for _, call in ipairs(msg.tool_calls) do
      if type(call) == "table" and type(call.id) == "string" then
        local fn = type(call["function"]) == "table" and call["function"] or {}
        local args = type(fn.arguments) == "string" and fn.arguments or ""
        table.insert(calls, {
          id         = call.id,
          type       = "function",
          ["function"] = {
            name      = "redacted",
            arguments = string.format('{"redacted_chars":%d}', #args),
          },
        })
      end
    end
    if #calls > 0 then
      out.tool_calls = calls
    end
  end
  return out
end
-- System and developer prompts: instructions to the agent, not its trajectory.
local function is_instruction(msg)
  return msg.role == "system" or msg.role == "developer"
end
-- Walks inbound messages and decides, per message, whether its text may leave
-- Kong under the configured prompt_disclosure policy.
local function filter_messages(conf, messages)
  if type(messages) ~= "table" then
    return {}
  end
  local disclosure = conf.prompt_disclosure or "none"
  if disclosure == "full" then
    return messages
  end
  local total = #messages
  local filtered = {}
  -- Indexes of the first and last messages with role == "user", and of the
  -- first assistant reply.
  local first_user_idx, last_user_idx, first_assistant_idx = nil, nil, nil
  for i = 1, total do
    local msg = messages[i]
    if type(msg) == "table" then
      if msg.role == "user" then
        first_user_idx = first_user_idx or i
        last_user_idx = i
      elseif msg.role == "assistant" then
        first_assistant_idx = first_assistant_idx or i
      end
    end
  end
  -- task_and_recent_window mirrors how Switchyard's escalation judge builds
  -- its transcript (summarize_for_judge upstream): every user message before
  -- the first assistant reply is task framing and always shown; after that,
  -- the last TASK_WINDOW non-instruction messages. System and developer
  -- messages stay redacted: the judge caps them hard because they carry no
  -- trajectory signal, and harness system prompts are large.
  local window_start = total + 1
  if disclosure == "task_and_recent_window" then
    local seen = 0
    for i = total, 1, -1 do
      local msg = messages[i]
      local framing = type(msg) == "table" and msg.role == "user"
                      and (not first_assistant_idx or i < first_assistant_idx)
      if type(msg) == "table" and not framing and not is_instruction(msg) then
        if seen == TASK_WINDOW then
          break
        end
        seen = seen + 1
        window_start = i
      end
    end
  end
  for i, msg in ipairs(messages) do
    if type(msg) ~= "table" then
      -- Pass unparseable elements through redacted rather than drop them;
      -- preserves turn count.
      table.insert(filtered, { role = "user", content = redact(nil) })
    else
      local keep = false
      if disclosure == "latest_user_prompt" then
        keep = (i == last_user_idx)
      elseif disclosure == "task_and_latest_user_prompt" then
        -- The opening task and the latest follow-up: what Switchyard's
        -- llm_classifier judge reads by default (task_messages() upstream),
        -- and nothing it does not.
        keep = (i == first_user_idx or i == last_user_idx)
      elseif disclosure == "task_and_recent_window" then
        if not is_instruction(msg) then
          local framing = msg.role == "user"
                          and (not first_assistant_idx or i < first_assistant_idx)
          keep = framing or i >= window_start
        end
      elseif disclosure == "recent_message_window" then
        keep = (i > total - RECENT_WINDOW)
      end
      -- disclosure == "none": keep stays false for every message
      if keep then
        local out = { role = msg.role, content = msg.content }
        for _, field in ipairs(TOOL_FIELDS) do
          out[field] = msg[field]
        end
        table.insert(filtered, out)
      else
        table.insert(filtered, redact_message(msg))
      end
    end
  end
  return filtered
end
-- djb2 string hash. Deliberately simple: runs inside the request path on
-- short strings, needs no external library, stable across LuaJIT restarts.
-- Returned as 8 hex chars.
local function hash_string(str)
  local hash = 5381
  for i = 1, #str do
    hash = (hash * 33 + str:byte(i)) % 0x100000000
  end
  return string.format("%08x", hash)
end
-- Pulls the text of the first user message out of an OpenAI-format body.
-- Used as a last-resort session key when the caller provides no correlation
-- headers at all. Returns nil if the body has no user message.
local function first_user_prompt(body)
  if type(body) ~= "table" or type(body.messages) ~= "table" then
    return nil
  end
  for _, msg in ipairs(body.messages) do
    if type(msg) == "table" and msg.role == "user" then
      if type(msg.content) == "string" then
        return msg.content
      elseif type(msg.content) == "table" then
        for _, part in ipairs(msg.content) do
          if type(part) == "table" and type(part.text) == "string" then
            return part.text
          end
        end
      end
    end
  end
  return nil
end
-- Returns the header's value, or nil when it is missing or blank.
local function header_value(name)
  local val = kong.request.get_header(name)
  if type(val) == "string" and val:find("%S") then
    return val
  end
  return nil
end
-- The session a coding harness sent, resolved in Switchyard's own precedence
-- order. Returns nil when the caller sent none.
local function harness_session_id()
  for _, hname in ipairs(HARNESS_SESSION_HEADERS_BEFORE_CODEX) do
    local val = header_value(hname)
    if val then
      return val
    end
  end
  local codex = header_value(HEADER_CODEX_TURN_METADATA)
  if codex then
    local meta = cjson.decode(codex)
    if type(meta) == "table" and type(meta.session_id) == "string"
       and meta.session_id:find("%S") then
      return meta.session_id
    end
  end
  return header_value(HARNESS_SESSION_HEADER_AFTER_CODEX)
end
-- Derives request_id and session_id from request context, with fallbacks.
--
-- request_id:
--   1. Inbound X-Switchyard-Request-Id header (caller-assigned)
--   2. Inbound X-Request-Id, then X-Client-Request-Id (Switchyard's aliases)
--   3. Kong's request ID (generated by Kong core / correlation-id plugin)
--
-- session_id:
--   1. Inbound X-Switchyard-Session-Id header (explicit session)
--   2. A harness session header (Claude Code, NeMo Relay, OpenCode, Codex,
--      generic `session-id`), in Switchyard's precedence order. Without this
--      step the fallbacks below would override a session the client did send.
--   3. If conf.session_from_prompt is true: hash of the first user prompt.
--      A multi-turn conversation that preserves message history produces the
--      same hash on every turn, which is what stateful routes (classifier
--      `user_turn`, escalation latch, advisor review budget) key on, even
--      through callers like Harbor that cannot send custom headers.
--   4. Fallback: request_id. Every request is its own session; stage routing
--      collapses to turn 0, which is safe.
local function derive_ids(conf, body)
  local request_id = header_value(HEADER_REQUEST_ID)
  if not request_id then
    for _, hname in ipairs(HARNESS_REQUEST_ID_HEADERS) do
      request_id = header_value(hname)
      if request_id then
        break
      end
    end
  end
  request_id = request_id or header_value("Kong-Request-Id")
  if not request_id then
    -- Last-ditch request ID so the decision service never sees an empty header.
    request_id = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
  end
  local session_id = header_value(HEADER_SESSION_ID) or harness_session_id()
  if not session_id and conf.session_from_prompt and body then
    local prompt = first_user_prompt(body)
    if prompt and prompt ~= "" then
      session_id = "p-" .. hash_string(prompt)
    end
  end
  return request_id, session_id or request_id
end
-- Builds the payload for `POST /v1/decision`.
--
-- Upstream contract:
--   input_format: matches inbound_profile (e.g. "openai_chat")
--   request.model: names the Switchyard route to evaluate
--   request.messages: filtered under prompt_disclosure
local function build_decision_request(conf, body)
  local messages
  if type(body) == "table" and type(body.messages) == "table" then
    messages = filter_messages(conf, body.messages)
  else
    messages = { { role = "user", content = redact(nil) } }
  end
  return {
    input_format = conf.inbound_profile,
    request = {
      model    = conf.decision_route,
      messages = messages,
    },
  }
end
-- Normalizes a `/v1/decision` body into the flat shape the rest of this plugin
-- works with. Returns nil + reason on anything unexpected.
--
-- The response carries no schema tag and no confidence score, so the presence
-- of a well-formed `selected.target` is the only validity signal available.
local function normalize_decision(decoded)
  local selected = decoded.selected
  if type(selected) ~= "table" or type(selected.target) ~= "string" then
    return nil, "decision response missing 'selected.target'"
  end
  local client = type(selected.llm_client) == "table" and selected.llm_client or {}
  return {
    backend_id = selected.target,
    model      = selected.model,
    protocol   = client.format,
    base_url   = client.base_url,
    fallbacks  = type(decoded.fallbacks) == "table" and #decoded.fallbacks or 0,
  }
end
-- Returns decision table, or nil + reason. Never throws.
local function fetch_decision(conf, body)
  local httpc, err = http.new()
  if not httpc then
    return nil, "http client unavailable: " .. tostring(err)
  end
  httpc:set_timeout(conf.timeout_ms)
  local payload = cjson.encode(build_decision_request(conf, body))
  local request_id, session_id = derive_ids(conf, body)
  local headers = {
    ["Content-Type"]    = "application/json",
    [HEADER_SESSION_ID] = session_id,
    [HEADER_REQUEST_ID] = request_id,
  }
  for _, hname in ipairs(FORWARD_CORRELATION_HEADERS) do
    local val = kong.request.get_header(hname)
    if val then
      headers[hname] = val
    end
  end
  -- Deliberately no retry. The call is advisory and fails open, so a retry buys
  -- a marginally better chance of a decision at the cost of doubling the delay
  -- added to every request during an outage. Serving promptly from
  -- default_target is the better trade.
  local res, rerr = httpc:request_uri(conf.decision_api_url, {
    method            = "POST",
    body              = payload,
    headers           = headers,
    keepalive_timeout = conf.keepalive_timeout or 60000,
    keepalive_pool    = conf.keepalive_pool or 10,
  })
  if not res then
    return nil, "decision call failed: " .. tostring(rerr)
  end
  if res.status ~= 200 then
    return nil, "decision service returned HTTP " .. tostring(res.status)
  end
  local decoded = cjson.decode(res.body or "")
  if type(decoded) ~= "table" then
    return nil, "malformed decision body"
  end
  return normalize_decision(decoded)
end
-- Validates a decision against the binding it claims to select.
--
-- The Decision API echoes the target's model and client settings alongside its
-- name. Where a bound value exists, they must match exactly; a mismatch means
-- the decision service and the gateway disagree about what that target *is*,
-- which is target drift and must fail open rather than dispatch.
--
-- `base_url` is the sharpest of the three: it is the field that would send
-- traffic somewhere Kong never approved, so a Switchyard target repointed at a
-- new provider is caught here even when the model name is unchanged.
local function check_binding(target, decision)
  local checks = {
    { field = "model",    bound = target.model,    got = decision.model },
    { field = "protocol", bound = target.protocol, got = decision.protocol },
    { field = "base_url", bound = target.base_url, got = decision.base_url },
  }
  for _, c in ipairs(checks) do
    -- Only assert on fields the decision actually asserted.
    if type(c.got) == "string" and c.bound and c.bound ~= "" and c.got ~= c.bound then
      return false, "target drift: decision " .. c.field .. " '" .. c.got ..
                    "' does not match bound '" .. c.bound .. "'"
    end
  end
  return true
end
local function parse_url(url)
  local scheme, hostport, path = url:match("^(https?)://([^/]+)(.*)$")
  if not scheme then
    return nil
  end
  local host, port = hostport:match("^([^:]+):?(%d*)$")
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  if path == "" then
    path = "/"
  end
  return scheme, host, port, path
end
-- Load ai_model(s) object from the datastore in RAM
local function load_ai_model(model_string)
  local entity, err = kong.db.ai_models:select_by_name(model_string)
  if err then
    return nil, err
  end
  if entity then
    return entity
  end
  -- name miss: fall back to the (optional) alias. Name precedence is preserved
  -- because select_by_name is tried first.
  entity, err = kong.db.ai_models:select_by_alias(model_string)
  if err then
    return nil, err
  end
  return entity
end
-- Applies a validated target. Returns true, or false + reason so the caller
-- can fall back rather than fail the request.
local function apply_target(conf, target, body)
  if conf.dispatch == "upstream" then
    local scheme, host, port, path = parse_url(target.upstream_url)
    if not scheme then
      return false, "unparseable upstream_url"
    end
    -- Retarget only. The body still names whatever model the client asked for,
    -- so this mode reaches a stub, not a provider -- see the schema notes.
    kong.service.set_target(host, port)
    kong.service.request.set_scheme(scheme)
    kong.service.request.set_path(path)
    return true
  elseif conf.dispatch == "konnect_model" then
    -- Query datastore for the selected model 'alias' from SwitchYard (OpenRouter?)
    local cache_key = kong.db.ai_models:cache_key(target.model)
    local entity, err = kong.cache:get(cache_key, nil, load_ai_model, target.model)
    if (not entity) or err then
      kong.log.err("error finding model ", target.model, " in datastore: ", err)
      return kong.response.exit(400, {
        error = true,
        message = "unable to find model " .. (target.model or "NONE_SENT") .. " in deployed Konnect AI Gateway models"
      })
    end
    ngx.ctx.ai_model = entity
    kong.log.notice("Set '", entity.alias or entity.name, "' (", entity.id, ") as the active model")
    return true
  end
  -- dispatch == "model_alias": rewrite the model to the target's alias so
  -- ai-proxy-advanced's extract-model-alias filter selects the matching
  -- target. Kong still owns credentials, provider config and dispatch.
  if type(body) ~= "table" then
    return false, "cannot rewrite model alias: request body is not JSON"
  end
  body.model = target.model_alias
  local encoded = cjson.encode(body)
  if not encoded then
    return false, "failed to re-encode request body"
  end
  kong.service.request.set_raw_body(encoded)
  return true
end
function AiRoutingProvider:access(conf)
  local ctx = kong.ctx.plugin
  local raw  = kong.request.get_raw_body()
  local body = raw and cjson.decode(raw) or nil
  local decision, reason = fetch_decision(conf, body)
  local backend_id, fallbacks
  if decision then
    -- The safety property, enforced here and nowhere else.
    local target = conf.targets[decision.backend_id]
    if target then
      local ok, drift = check_binding(target, decision)
      if ok then
        backend_id = decision.backend_id
        fallbacks  = decision.fallbacks
      else
        reason = drift
      end
    else
      reason = "unknown target '" .. decision.backend_id .. "'"
    end
  end
  if not backend_id then
    -- Fallback path. A routing-decision failure must never become a
    -- user-facing error.
    backend_id = conf.default_target
    ctx.outcome = OUTCOME_FALLBACK
    ctx.backend_id = backend_id
    log_decision({
      outcome    = OUTCOME_FALLBACK,
      mode       = conf.mode,
      backend_id = backend_id,
      reason     = reason,
    })
    if conf.mode == "enforce" then
      apply_target(conf, conf.targets[backend_id], body)
    end
    return
  end
  if conf.mode == "observe_only" then
    -- Log what we would have done; leave routing untouched.
    ctx.outcome = OUTCOME_OBSERVED
    ctx.backend_id = backend_id
    log_decision({
      outcome    = OUTCOME_OBSERVED,
      mode       = conf.mode,
      backend_id = backend_id,
      fallbacks  = fallbacks,
    })
    return
  end
  local ok, apply_err = apply_target(conf, conf.targets[backend_id], body)
  if not ok then
    backend_id = conf.default_target
    ctx.outcome = OUTCOME_FALLBACK
    ctx.backend_id = backend_id
    log_decision({
      outcome    = OUTCOME_FALLBACK,
      mode       = conf.mode,
      backend_id = backend_id,
      reason     = apply_err,
    })
    apply_target(conf, conf.targets[backend_id], body)
    return
  end
  ctx.outcome = OUTCOME_ENFORCED
  ctx.backend_id = backend_id
  log_decision({
    outcome    = OUTCOME_ENFORCED,
    mode       = conf.mode,
    backend_id = backend_id,
    fallbacks  = fallbacks,
  })
end
function AiRoutingProvider:header_filter(conf)
  local ctx = kong.ctx.plugin
  if ctx.backend_id then
    kong.response.set_header("X-AI-Routing-Backend", ctx.backend_id)
    kong.response.set_header("X-AI-Routing-Outcome", ctx.outcome or "unknown")
  end
end
return AiRoutingProvider
