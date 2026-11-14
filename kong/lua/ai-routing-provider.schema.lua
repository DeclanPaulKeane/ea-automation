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
local typedefs = require "kong.db.schema.typedefs"
-- Protocol/endpoint pairs are fixed by the Switchyard Decision API contract.
-- Source: crates/switchyard-server/README.md on upstream main.
local PROTOCOL_ENDPOINT = {
  openai_chat        = "/v1/chat/completions",
  openai_responses   = "/v1/responses",
  anthropic_messages = "/v1/messages",
}
local PROTOCOLS = { "openai_chat", "openai_responses", "anthropic_messages" }
-- A Kong-owned binding. The decision service returns a key into this map and
-- nothing else -- it can never supply a URL.
--
-- `model` is the real provider model. `model_alias` is what Kong's
-- ai-proxy-advanced matches on. Keeping both lets us verify a decision against
-- its binding (target-drift detection) while still dispatching by alias.
local target_record = {
  type = "record",
  fields = {
    -- Used when dispatch = "upstream" (stub/no-license testing).
    { upstream_url = {
        type = "string",
        description = "Target upstream base URL when dispatch is 'upstream'.",
    } },
    -- Used when dispatch = "model_alias" (Kong-native, via ai-proxy-advanced).
    { model_alias  = {
        type = "string",
        description = "Model alias recognized by ai-proxy-advanced when dispatch is 'model_alias'.",
    } },
    -- Real provider model name. Checked against the decision to catch drift.
    { model        = {
        type = "string",
        description = "Underlying LLM model name. Verified against decision to prevent drift.",
    } },
    -- Informational. Not used for dispatch.
    { provider     = {
        type = "string",
        description = "Optional provider name for informational and telemetry purposes.",
    } },
    { protocol     = {
        type = "string",
        default = "openai_chat",
        one_of = PROTOCOLS,
        description = "Protocol format used by the target LLM provider.",
    } },
    -- The decision service's own base URL for this target, echoed back as
    -- `selected.llm_client.base_url`. Set it to assert that Switchyard has not
    -- been repointed at a provider Kong never approved.
    { base_url     = {
        type = "string",
        description = "Approved base URL for target to assert Switchyard has not been repointed.",
    } },
  },
}
local function validate(config)
  if type(config.targets) ~= "table" or next(config.targets) == nil then
    return nil, "'targets' must contain at least one entry"
  end
  if config.targets[config.default_target] == nil then
    return nil, "'default_target' must reference a key in 'targets' (got '"
                .. tostring(config.default_target) .. "')"
  end
  for id, target in pairs(config.targets) do
    if config.dispatch == "upstream" then
      if not target.upstream_url or target.upstream_url == "" then
        return nil, "target '" .. id ..
                    "' requires 'upstream_url' when dispatch = 'upstream'"
      end
      if not target.upstream_url:match("^https?://[^/]+") then
        return nil, "target '" .. id ..
                    "' has a malformed 'upstream_url' (want http(s)://host[:port][/path])"
      end
    elseif config.dispatch == "model_alias" then
      if not target.model_alias or target.model_alias == "" then
        return nil, "target '" .. id ..
                    "' requires 'model_alias' when dispatch = 'model_alias'"
      end
    end
    -- Protocol/endpoint pairs are fixed by the Decision API contract; a
    -- mismatch here would make target-drift checks meaningless.
    local want = PROTOCOL_ENDPOINT[target.protocol or "openai_chat"]
    if want == nil then
      return nil, "target '" .. id .. "' has an unknown protocol '" ..
                  tostring(target.protocol) .. "'"
    end
  end
  -- Same contract applies to the inbound side we advertise.
  local want_inbound = PROTOCOL_ENDPOINT[config.inbound_profile or "openai_chat"]
  if config.inbound_endpoint and config.inbound_endpoint ~= ""
     and config.inbound_endpoint ~= want_inbound then
    return nil, "'inbound_profile' " .. tostring(config.inbound_profile) ..
                " requires 'inbound_endpoint' '" .. want_inbound ..
                "' (got '" .. config.inbound_endpoint .. "')"
  end
  return true
end
return {
  name = "ai-routing-provider",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { decision_api_url = typedefs.url {
              required = true,
              description = "Endpoint URL for the external routing decision service (e.g. http://switchyard:4000/v1/decision).",
          } },
          -- Sent as the nested request's `model`. Names a route in the
          -- decision service's own config, e.g. `switchyard/general`.
          { decision_route = {
              type = "string",
              required = true,
              description = "Route or profile name configured in Switchyard server.",
          } },
          -- How much of the live conversation the decision request may carry.
          -- `/v1/decision` has no server-side summary mode, so this is enforced
          -- by Kong: under "none" every message is replaced by a size marker
          -- before encoding, and prompt content never leaves Kong. Anything
          -- richer is a privacy decision, hence the default.
          -- "task_and_latest_user_prompt" discloses exactly the two user messages
          -- Switchyard's llm_classifier judge reads by default -- the opening task
          -- and the latest follow-up -- and redacts everything between, tool
          -- results included.
          -- "task_and_recent_window" discloses what Switchyard's escalation judge
          -- reads: the task framing (every user message before the first
          -- assistant reply) and the last 28 non-system messages, tool calls and
          -- results included. System and developer prompts stay redacted.
          { prompt_disclosure = {
              type    = "string",
              default = "none",
              one_of  = {
                "none", "latest_user_prompt", "task_and_latest_user_prompt",
                "recent_message_window", "task_and_recent_window", "full",
              },
              description = "Scope of prompt content disclosed to Switchyard ('none', 'latest_user_prompt', 'task_and_latest_user_prompt', 'recent_message_window', 'task_and_recent_window', 'full').",
          } },
          -- Inbound protocol advertised to the decision service. The pairing
          -- is fixed by the Switchyard contract, so the two are validated
          -- together rather than set independently.
          { inbound_profile = {
              type    = "string",
              default = "openai_chat",
              one_of  = PROTOCOLS,
              description = "Protocol format of inbound client requests sent to Kong.",
          } },
          { inbound_endpoint = {
              type = "string",
              default = "/v1/chat/completions",
              description = "Inbound request URI matching the advertised profile.",
          } },
          -- Derive session_id from a hash of the first user message when the
          -- caller sent neither X-Switchyard-Session-Id nor a harness session
          -- header (x-claude-code-session-id, x-session-id, session-id, ...).
          -- Harbor cannot set headers, and the request_id fallback makes every
          -- request its own session, so stateful routes never hold state.
          { session_from_prompt = {
              type = "boolean",
              default = false,
              description = "Derive session ID from prompt hash when client does not supply a session header.",
          } },
          { targets = {
              type        = "map",
              required    = true,
              keys        = { type = "string" },
              values      = target_record,
              description = "Map of pre-approved target configurations that Switchyard decisions are permitted to select.",
          } },
          { default_target = {
              type = "string",
              required = true,
              description = "Fallback target ID used when Switchyard is unreachable or decision is rejected.",
          } },
          -- Every environment starts in observe_only. Flipping to enforce is
          -- an explicit, reviewable config change.
          { mode = {
              type    = "string",
              default = "observe_only",
              one_of  = { "observe_only", "enforce" },
              description = "Operational mode: 'observe_only' evaluates routing without modifying traffic; 'enforce' actively routes request.",
          } },
          -- How an enforced decision is applied:
          --   model_alias   -> rewrite body.model so ai-proxy-advanced selects
          --                    the target (the supported production path)
          --   upstream      -> retarget only. body.model is left alone, so this
          --                    reaches a stub, not a provider.
          --   konnect_model -> queries the datastore for the corresponding "konnect aigw model"
          --                    and sets up the targeting accordingly.
          --                    this should make it fully compatible with Kong's new AIGW product.
          { dispatch = {
              type    = "string",
              default = "model_alias",
              one_of  = { "model_alias", "upstream", "konnect_model" },
              description = "Dispatch mechanism: 'model_alias' rewrites model for ai-proxy-advanced; 'upstream' overrides service upstream.",
          } },
          { timeout_ms = {
              type = "number",
              default = 300,
              between = { 1, 60000 },
              description = "HTTP timeout in milliseconds when querying Switchyard Decision API.",
          } },
          { keepalive_timeout = {
              type = "number",
              default = 60000,
              description = "Keepalive idle timeout in milliseconds for HTTP connections to Switchyard.",
          } },
          { keepalive_pool = {
              type = "integer",
              default = 10,
              description = "Maximum idle connections kept in the pool for the Decision API client.",
          } },
        },
    } },
  },
}
