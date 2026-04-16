---@meta

-- Compatibility type shims for EmmyLua strict diagnostics.
-- These are intentionally minimal and only define names used in annotations.

---@class TestSpy
---@field calls table[]
---@field call_count integer
---@field called_with fun(self: TestSpy, ...: any): boolean
---@field revert fun(self: TestSpy): nil
---@field reset fun(self: TestSpy): nil

---@class TestStub: TestSpy
---@field invoke_callback fun(self: TestStub, callback_index: integer, ...: any): any
---@field invokes fun(self: TestStub, fn: function): TestStub

---@class vim.Diagnostic
---@field bufnr integer
---@field lnum integer
---@field col integer
---@field severity integer
---@field message string
---@field source string|nil
---@field code string|integer|nil

---@class vim.diagnostic.GetOpts

---@alias vim.diagnostic.Severity integer
---@alias vim.log.levels integer
---@alias vim.NIL userdata

---@class uv.uv_timer_t
---@class uv.uv_pipe_t
---@class uv.uv_process_t

---@alias TSNode any
