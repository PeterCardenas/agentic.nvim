local assert = require("tests.helpers.assert")
local CursorACPAdapter = require("agentic.acp.adapters.cursor_acp_adapter")

describe("agentic.acp.adapters.CursorACPAdapter", function()
    it("formats read arguments with line ranges", function()
        local argument = CursorACPAdapter:_format_read_argument({
            file_path = "/tmp/example.lua",
            line = 10,
            limit = 5,
        }, nil)

        assert.equal("/tmp/example.lua:10-14", argument)
    end)

    it("formats search arguments from query and path metadata", function()
        local argument = CursorACPAdapter:_format_search_argument({
            query = "MessageWriter",
            path = "/tmp/project",
            glob = "*.lua",
        }, nil)

        assert.equal("MessageWriter path=/tmp/project glob=*.lua", argument)
    end)

    it("strips duplicated kind from fallback read title", function()
        local argument =
            CursorACPAdapter:_format_read_argument(nil, "Read lua/init.lua")

        assert.equal("lua/init.lua", argument)
    end)

    it("does not build edit diff when raw input has no diff payload", function()
        local diff = CursorACPAdapter:_build_edit_diff({
            file_path = "/tmp/example.lua",
        })

        assert.is_nil(diff)
    end)

    it("builds edit diff when new content is present", function()
        local diff = CursorACPAdapter:_build_edit_diff({
            file_path = "/tmp/example.lua",
            new_string = "new content",
            old_string = "old content",
        })

        assert.is_not_nil(diff)
        local resolved_diff = assert.not_nil(diff)
        assert.same({ "new content" }, resolved_diff.new)
        assert.same({ "old content" }, resolved_diff.old)
    end)
end)
