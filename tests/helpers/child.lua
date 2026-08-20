-- Helper to create isolated child Neovim instances with plugin loaded

local MiniTest = require("mini.test")

--- @class tests.helpers.Child : MiniTest.child
--- @field setup fun() Restart child and load plugin and run agentic.setup() to run auto commands and configurations
--- @field flush fun() Flush pending scheduled callbacks in child neovim and wait a bit to ensure they are processed
--- @field stop fun()
--- @field v table
--- @field api table
--- @field g table
--- @field fn table
--- @field lua fun(code: string, args: table|nil)
--- @field type_keys fun(...: string)
--- @field wait_for_buffer_text fun(self: tests.helpers.Child, bufnr: number, marker: string, timeout_ms: number): boolean

--- @class tests.helpers.ChildModule
local M = {}

--- Create a new child Neovim instance with the plugin pre-loaded
--- @return tests.helpers.Child child Child Neovim instance with setup() method
function M.new()
    local child = MiniTest.new_child_neovim() --[[@as tests.helpers.Child]]
    local root_dir = vim.fn.getcwd()

    function child.setup()
        child.restart({ "-u", "NONE" })
        child.lua("vim.opt.rtp:prepend(...)", { root_dir })

        child.lua([[
            local ACPTransportMock = require("tests.mocks.acp_transport_mock")
            package.loaded["agentic.acp.acp_transport"] = ACPTransportMock
        ]])

        child.lua([[
            local ACPHealthMock = require("tests.mocks.acp_health_mock")
            package.loaded["agentic.acp.acp_health"] = ACPHealthMock
        ]])

        child.lua([[
            require("agentic").setup()
        ]])
    end

    function child.flush()
        child.lua([[
          vim.cmd("redraw")
        ]])

        child.api.nvim_eval("1")
    end

    --- Wait for asynchronous terminal output from the parent process.
    --- @param bufnr number
    --- @param marker string
    --- @param timeout_ms number
    --- @return boolean found
    function child:wait_for_buffer_text(bufnr, marker, timeout_ms)
        for _ = 1, math.floor(timeout_ms / 10) do
            local lines = self.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            if table.concat(lines, "\\n"):find(marker, 1, true) ~= nil then
                return true
            end
            vim.uv.sleep(10)
        end
        return false
    end

    return child
end

return M
