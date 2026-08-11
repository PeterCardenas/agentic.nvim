# Provider System

## ACP Providers (Agent Client Protocol)

This plugin spawn **external CLI tools** as subprocesses and communicate via the
Agent Client Protocol:

- **Requirements**: External CLI tools must be installed by the user, we don't
  install them for security reasons.
  - `claude-agent-acp` for Claude
  - `gemini` for Gemini
  - `codex-acp` for Codex
  - `opencode` for OpenCode
  - `cursor-agent-acp` for Cursor Agent
  - `auggie` for Augment Code
  - `vibe-acp` for Mistral Vibe

NOTE: Install instructs are in the README.md

## Provider adapters:

Each provider has a dedicated adapter in `lua/agentic/acp/adapters/`

These adapters implement provider-specific message formatting, tool call
handling, and protocol quirks.

## ACP provider configuration:

```lua
acp_providers = {
  ["claude-agent-acp"] = {
    name = "Claude Agent ACP",             -- Display name
    command = "claude-agent-acp",          -- CLI command to spawn
    env = {                                -- Environment variables
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
  ["gemini-acp"] = {
    name = "Gemini ACP",
    command = "gemini",
    args = { "--experimental-acp" },       -- CLI arguments
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
}
```

## Event pipeline (top to bottom)

```
Provider subprocess (external CLI)
  | stdio: newline-delimited JSON-RPC
  v
ACPTransport      -- parses JSON, calls callbacks.on_message()
  |
  v
ACPClient         -- routes by message type (notification vs response)
  |  adapter override point: __handle_tool_call,
  |  __handle_tool_call_update, __build_tool_call_update
  v
SessionManager    -- registered as subscriber per session_id
  |  routes by sessionUpdate type
  |  (see "Session update routing" below)
  v
MessageWriter     -- writes to chat buffer, tracks tool call state
PermissionManager -- queues permission prompts, manages keymaps
ChatHistory       -- accumulates messages for persistence
```

## Session update routing

`ACPClient` receives `session/update` notifications. The `sessionUpdate` field
determines routing:

| `sessionUpdate` value   | Routed to                                  |
| ----------------------- | ------------------------------------------ |
| `"tool_call"`           | adapter `__handle_tool_call` → subscriber  |
| `"tool_call_update"`    | adapter `__handle_tool_call_update` → sub  |
| `"agent_message_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"agent_thought_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"plan"`                | `TodoList.render()`                        |
| `"request_permission"`  | `PermissionManager` (queued, sequential)   |
| others                  | `subscriber.on_session_update()` (generic) |

## Tool call lifecycle

Tool calls go through **3 phases**. `MessageWriter` tracks each via
`tool_call_blocks[tool_call_id]`, persisting state across all phases.

**Phase 1 — `tool_call` (initial)**

```
Provider sends "tool_call"
  -> Adapter builds ToolCallBlock { tool_call_id, kind, argument, status, body?, diff? }
  -> subscriber.on_tool_call(block)
  -> MessageWriter:write_tool_call_block(block)
     1. Renders header + body/diff lines to buffer
     2. Creates range extmark (NS_TOOL_BLOCKS) as position anchor
     3. Creates decoration extmarks (borders, status icon)
     4. Stores block in tool_call_blocks[id]
```

**Phase 2 — `tool_call_update` (one or more)**

```
Provider sends "tool_call_update"
  -> Adapter builds ToolCallBase { tool_call_id, status, body?, diff? }
     (only CHANGED fields needed — MessageWriter merges)
  -> subscriber.on_tool_call_update(partial)
  -> MessageWriter:update_tool_call_block(partial)
     1. Looks up tracker = tool_call_blocks[id]
     2. Deep-merges via tbl_deep_extend("force", tracker, partial)
     3. Replaces the body snapshot when a new body is provided
     4. Locates block position via range extmark
     5. Diff already rendered: refresh decorations + status only
        (content frozen to prevent flicker)
     6. Diff is NEW: replace buffer lines, re-render everything
```

**Phase 3 — final `tool_call_update` with terminal status**

```
Same as Phase 2, but status = "completed" | "failed" | "cancelled"
  -> Visual status icon updates to final state
  -> If "failed" or "cancelled": PermissionManager removes pending request
```

## Key design rules for adapters

- **Updates are partial:** Only send what changed. MessageWriter merges onto the
  existing tracker via `tbl_deep_extend`.
- **Diffs are immutable after first render:** Once a diff is written to the
  buffer, content is frozen. Only status/decorations refresh on subsequent
  updates.
- **Body snapshots replace:** Generic tool-call updates replace the prior body
  when a new body is provided; they do not accumulate provider deltas.
- **Mistral raw-output deltas:** The Mistral adapter is responsible for
  provider-specific delta aggregation and keeps a provider-local aggregate
  keyed by session ID and `toolCallId`, preserving update order within each
  session and clearing it on `completed`, `failed`, or `cancelled`. When raw
  output contains both streams, fields are rendered in deterministic `stdout`
  then `stderr` order; this is field order, not a claim about emission
  chronology.
- **Extmarks as position anchors:** Range extmark in `NS_TOOL_BLOCKS`
  auto-adjusts when buffer content shifts. Single source of truth for block
  position.

## Permission flow (interleaved with tool calls)

```
Provider sends "session/request_permission"
  -> SessionManager: opens diff preview in editor window (if kind = "diff")
  -> PermissionManager:add_request(request, callback)
     -> Queues request (sequential — one prompt at a time)
     -> Renders permission buttons in chat buffer
     -> Sets up buffer-local keymaps (1,2,3,4)
  -> User presses key
     -> Sends result back to provider via callback
     -> Clears diff preview
     -> Dequeues next permission if any
```

## Adapter override points

Each provider adapter can override these **protected** methods on `ACPClient`:

| Method                        | Default behavior                          |
| ----------------------------- | ----------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock from standard fields |
| `__build_tool_call_update`    | Builds ToolCallBase with status + body    |
| `__handle_tool_call_update`   | Calls build then notifies subscriber      |
| `__handle_request_permission` | Sends result back to provider             |

Override when the provider sends data in non-standard fields (e.g. `rawInput`,
`rawOutput`), needs synthetic events (Gemini synthesizes `tool_call` from
permission request), or skips events (Gemini doesn't send cancel updates on
rejection).
