--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")

local ACPTransport = require("agentic.acp.acp_transport")

describe("agentic.acp.acp_transport", function()
    describe("stderr tail buffering", function()
        it("keeps only the most recent stderr chunks", function()
            assert.is_not_nil(ACPTransport._append_stderr_tail)

            local buffer = {}
            for i = 1, 60 do
                ACPTransport._append_stderr_tail(buffer, "stderr " .. i)
            end

            assert.equal(50, #buffer)
            assert.equal("stderr 11", buffer[1])
            assert.equal("stderr 60", buffer[#buffer])
        end)
    end)
end)
