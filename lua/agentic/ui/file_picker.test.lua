local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local FilePicker = require("agentic.ui.file_picker")

--- Computes the differences between two tables
--- @param left table
--- @param right table
--- @return string[] only_in_left Items only in left table
--- @return string[] only_in_right Items only in right table
local function table_diff(left, right)
    local left_set = {}
    for _, v in ipairs(left) do
        left_set[v] = true
    end

    local right_set = {}
    for _, v in ipairs(right) do
        right_set[v] = true
    end

    local only_in_left = {}
    for _, v in ipairs(left) do
        if not right_set[v] then
            table.insert(only_in_left, v)
        end
    end

    local only_in_right = {}
    for _, v in ipairs(right) do
        if not left_set[v] then
            table.insert(only_in_right, v)
        end
    end

    return only_in_left, only_in_right
end

describe("FilePicker:scan_files", function()
    --- @type TestStub|nil
    local system_stub
    local original_cmd_rg
    local original_cmd_fd
    local original_cmd_git

    before_each(function()
        original_cmd_rg = FilePicker.CMD_RG[1]
        original_cmd_fd = FilePicker.CMD_FD[1]
        original_cmd_git = FilePicker.CMD_GIT[1]
    end)

    after_each(function()
        if system_stub then
            system_stub:revert()
            system_stub = nil
        end
        FilePicker.CMD_RG[1] = original_cmd_rg
        FilePicker.CMD_FD[1] = original_cmd_fd
        FilePicker.CMD_GIT[1] = original_cmd_git
    end)

    describe("mocked commands", function()
        it("should stop at first successful command", function()
            -- Make all commands available by setting them to executables that exist
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"

            -- Reset shell_error to ensure clean state (may be non-zero from prior tests)
            vim.fn.system("true")

            system_stub = spy.stub(vim.fn, "system")
            system_stub:invokes(function(_cmd)
                -- First call is git rev-parse check (returns "" = not a git repo)
                -- Second call is rg scan (returns files = success)
                if system_stub.call_count == 1 then
                    return ""
                else
                    return "file1.lua\nfile2.lua\nfile3.lua\n"
                end
            end)

            local files = FilePicker.scan_files()

            -- git rev-parse returns "" with shell_error=0 so git is added as a command,
            -- then rg scan succeeds (returns files) = 2 total calls
            assert.equal(2, system_stub.call_count)
            assert.equal(3, #files)
        end)
    end)

    describe("real commands", function()
        local original_exclude_patterns

        before_each(function()
            original_exclude_patterns =
                vim.tbl_extend("force", {}, FilePicker.GLOB_EXCLUDE_PATTERNS)
        end)

        after_each(function()
            FilePicker.GLOB_EXCLUDE_PATTERNS = original_exclude_patterns
        end)

        it("should return same files in same order for all commands", function()
            -- Test rg
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = FilePicker.scan_files()

            -- Test fd
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = original_cmd_fd
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_fd = FilePicker.scan_files()

            -- Test git
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = original_cmd_git
            local files_git = FilePicker.scan_files()

            -- All commands should return more than 0 files
            assert.is_true(#files_rg > 0)
            assert.is_true(#files_fd > 0)
            assert.is_true(#files_git > 0)

            -- Extract just the word (filename) for comparison
            local words_rg = vim.tbl_map(function(f)
                return f.word
            end, files_rg)
            local words_fd = vim.tbl_map(function(f)
                return f.word
            end, files_fd)
            local words_git = vim.tbl_map(function(f)
                return f.word
            end, files_git)

            local rg_only, fd_only = table_diff(words_rg, words_fd)
            assert.are.same(rg_only, fd_only)

            local fd_only2, git_only = table_diff(words_fd, words_git)
            assert.are.same(fd_only2, git_only)

            assert.are.equal(#files_rg, #files_fd)
            assert.are.equal(#files_fd, #files_git)
        end)

        it("should use glob fallback when all commands fail", function()
            -- First, get files from rg for comparison
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            local files_rg = FilePicker.scan_files()

            -- Disable all commands to force glob fallback
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"

            -- deps is the temp folder where mini.nvim is installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "deps/")
            -- lazy_repro is the temp folder where plugins are installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "lazy_repro/")
            -- .local is the folder where Neovim is installed during tests in CI
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.local/")
            -- settings.local.json is gitignored but glob fallback doesn't respect .gitignore
            table.insert(
                FilePicker.GLOB_EXCLUDE_PATTERNS,
                "settings%.local%.json"
            )
            -- .opencode/.gitignore ignores specific files (bun.lock, package.json, etc.)
            -- rg/fd/git respect nested .gitignore but glob fallback doesn't
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.opencode/bun")
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.opencode/package")
            table.insert(
                FilePicker.GLOB_EXCLUDE_PATTERNS,
                "%.opencode/%.gitignore"
            )

            local files_glob = FilePicker.scan_files()

            assert.is_true(#files_glob > 0)

            -- Extract just the word (filename) for comparison
            local words_rg = vim.tbl_map(function(f)
                return f.word
            end, files_rg)
            local words_glob = vim.tbl_map(function(f)
                return f.word
            end, files_glob)

            local rg_only, glob_only = table_diff(words_rg, words_glob)
            assert.are.same(rg_only, glob_only)

            assert.are.equal(#words_rg, #words_glob)
        end)
    end)
end)

describe("FilePicker:open", function()
    after_each(function()
        package.loaded["fzf-lua"] = nil
    end)

    it(
        "pops upward above the agentic prompt with side-by-side preview",
        function()
            --- @type table|nil
            local captured_opts

            package.loaded["fzf-lua"] = {
                files = function(opts)
                    captured_opts = opts
                end,
            }

            FilePicker.open()

            captured_opts = assert.not_nil(captured_opts)
            assert.is_table(captured_opts)

            local winopts = captured_opts.winopts
            assert.equal("editor", winopts.relative)
            assert.equal(0, winopts.col)
            assert.equal(1, winopts.width)
            assert.equal(100, winopts.backdrop)
            assert.equal("horizontal", winopts.preview.layout)
            -- Bottom-anchored: top + height must end above the editor's last
            -- line minus cmdheight, so the picker never covers the prompt
            -- buffer.
            local cmdheight = vim.o.cmdheight or 1
            assert.is_true(winopts.row >= 0)
            assert.is_true(winopts.height > 0)
            assert.is_true(
                winopts.row + winopts.height <= vim.o.lines - cmdheight
            )

            -- fzf's prompt sits at the bottom of the picker.
            assert.equal("reverse-list", captured_opts.fzf_opts["--layout"])
        end
    )

    it("adds selected files from fzf picker callback", function()
        local on_selected = spy.new(function(_file_path) end)
        local on_complete = spy.new(function() end)

        package.loaded["fzf-lua"] = {
            files = function(opts)
                opts.actions["default"]({ " lua/agentic/init.lua" })
                local on_close = opts.winopts.on_close
                if type(on_close) == "function" then
                    on_close()
                end
            end,
            path = {
                entry_to_file = function(_entry, _opts)
                    return { path = "lua/agentic/init.lua" }
                end,
            },
        }

        FilePicker.open(
            on_selected --[[@as function]],
            on_complete --[[@as function]]
        )

        assert.spy(on_selected).was.called(1)
        assert.spy(on_complete).was.called(1)
        local file_path = on_selected.calls[1][1]
        assert.truthy(file_path:match("lua/agentic/init.lua$"))
    end)

    it("runs completion callback when fzf picker closes", function()
        local on_complete = spy.new(function() end)
        --- @type table|nil
        local captured_opts

        package.loaded["fzf-lua"] = {
            files = function(opts)
                captured_opts = opts
            end,
        }

        FilePicker.open(nil, on_complete --[[@as function]])

        captured_opts = assert.not_nil(captured_opts)
        local winopts = assert.not_nil(captured_opts.winopts)
        local on_close = assert.not_nil(winopts.on_close)
        on_close()

        assert.spy(on_complete).was.called(1)
    end)
end)
