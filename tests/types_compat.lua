---@meta

-- Compatibility type shims for the tests/ EmmyLua pass.

---@class agentic.acp.StdioTransportConfig
---@field command string[]

---@class agentic.acp.TransportCallbacks
---@field on_state_change fun(state: string): nil
---@field on_message fun(message: table): nil
---@field on_error fun(err: string): nil
---@field on_exit fun(code: integer, signal: integer): nil

---@class agentic.UserConfig.Folding
---@field enabled boolean
---@field min_lines integer

---@class agentic.UserConfig.AutoScroll
---@field threshold integer

---@class agentic.ui.MessageWriter.ToolCallBase
---@field tool_call_id string
---@field status string|nil
---@field body string|string[]|nil
---@field diff table|nil

---@class agentic.ui.MessageWriter.ToolCallBlock: agentic.ui.MessageWriter.ToolCallBase
---@field kind string
---@field argument string

---@class agentic.ui.ChatHistory.ToolCall
---@field type "tool_call"
---@field tool_call_id string
---@field kind string
---@field status string|nil
---@field argument string|nil
---@field body string|string[]|nil
---@field diff table|nil
