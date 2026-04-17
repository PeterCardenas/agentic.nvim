local assert = require("tests.helpers.assert")
local DiagnosticsContext = require("agentic.ui.diagnostics_context")

describe("agentic.ui.DiagnosticsContext", function()
    it("formats diagnostics for prompt and chat summary", function()
        --- @type agentic.ui.DiagnosticsContext.Diagnostic[]
        local diagnostics = {
            {
                bufnr = 1,
                lnum = 9,
                col = 4,
                severity = vim.diagnostic.severity.WARN,
                message = "Use <tag> & escape me",
                source = "lua_ls",
                code = "unused-local",
                file_path = "lua/agentic/session_manager.lua",
            },
        }

        local result = DiagnosticsContext.format_diagnostics(diagnostics, 120)

        assert.equal(1, #result.prompt_entries)
        assert.equal(1, #result.summary_lines)
        local first_prompt_entry = assert.not_nil(result.prompt_entries[1])
        local first_summary_line = assert.not_nil(result.summary_lines[1])
        local prompt_text = first_prompt_entry.text
        assert.equal("text", first_prompt_entry.type)
        assert.truthy(prompt_text:find("<severity>WARN</severity>", 1, true))
        assert.truthy(prompt_text:find("&lt;tag&gt; &amp; escape me", 1, true))
        assert.truthy(prompt_text:find("<source>lua_ls</source>", 1, true))
        assert.truthy(prompt_text:find("<code>unused-local</code>", 1, true))
        assert.truthy(prompt_text:find("<line>10</line>", 1, true))
        assert.truthy(prompt_text:find("<column>5</column>", 1, true))
        assert.truthy(
            first_summary_line:find(
                "[WARN] lua/agentic/session_manager.lua:10:5",
                1,
                true
            )
        )
    end)

    it("uses unnamed buffer fallback and truncates summary", function()
        --- @type agentic.ui.DiagnosticsContext.Diagnostic[]
        local diagnostics = {
            {
                bufnr = 1,
                lnum = 0,
                col = 0,
                severity = vim.diagnostic.severity.ERROR,
                message = "A very long diagnostic message that should be truncated",
                file_path = "",
            },
        }

        local result = DiagnosticsContext.format_diagnostics(diagnostics, 40)

        local first_prompt_entry = assert.not_nil(result.prompt_entries[1])
        local first_summary_line = assert.not_nil(result.summary_lines[1])
        local prompt_text = first_prompt_entry.text
        assert.truthy(
            prompt_text:find("<file>&lt;unnamed buffer&gt;</file>", 1, true)
        )
        assert.is_nil(prompt_text:find("<source>", 1, true))
        assert.is_nil(prompt_text:find("<code>", 1, true))
        assert.truthy(
            first_summary_line:find("[ERROR] <unnamed buffer>:1:1", 1, true)
        )
        assert.equal("...", first_summary_line:sub(-3))
    end)

    it("handles nil file_path as unnamed buffer", function()
        --- @type agentic.ui.DiagnosticsContext.Diagnostic[]
        local diagnostics = {
            {
                bufnr = 1,
                lnum = 0,
                col = 0,
                severity = vim.diagnostic.severity.ERROR,
                message = "some error",
                file_path = nil,
            },
        }

        local result = DiagnosticsContext.format_diagnostics(diagnostics, 120)

        local first_prompt_entry = assert.not_nil(result.prompt_entries[1])
        local first_summary_line = assert.not_nil(result.summary_lines[1])
        assert.truthy(
            first_prompt_entry.text:find(
                "<file>&lt;unnamed buffer&gt;</file>",
                1,
                true
            )
        )
        assert.truthy(first_summary_line:find("<unnamed buffer>:1:1", 1, true))
    end)
end)
