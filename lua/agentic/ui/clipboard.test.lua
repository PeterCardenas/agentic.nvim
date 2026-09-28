local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.clipboard", function()
    it("returns the saved path only after asynchronous success", function()
        local Clipboard = dofile("lua/agentic/ui/clipboard.lua")
        local original_plugin = package.loaded["img-clip"]
        local original_clipboard = package.loaded["img-clip.clipboard"]
        local installed_stub = spy.stub(Clipboard, "is_img_clip_installed")
        installed_stub:returns(true)
        --- @type fun(success: boolean)|nil
        local finish
        package.loaded["img-clip"] = {}
        package.loaded["img-clip.clipboard"] = {
            save_image_async = function(_, callback)
                finish = callback
            end,
        }
        local path
        local ok, err = pcall(function()
            Clipboard.paste_image_async(function(result)
                path = result
            end)
            assert.is_nil(path)
            assert.is_not_nil(finish)
            if not finish then
                return
            end
            finish(true)
            assert.is_not_nil(path)
            if not path then
                return
            end
            assert.is_true(path:match("pasted_image_.*%.png$") ~= nil)
        end)
        installed_stub:revert()
        package.loaded["img-clip"] = original_plugin
        package.loaded["img-clip.clipboard"] = original_clipboard
        if not ok then
            error(err)
        end
    end)
end)
