local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.FilePicker.FzfPathEntry
--- @field path? string
---
--- @class agentic.ui.FilePicker.FzfPathModule
--- @field entry_to_file fun(entry: string, opts: { cwd: string }): agentic.ui.FilePicker.FzfPathEntry
---
--- @class agentic.ui.FilePicker.FzfLua
--- @field files? fun(opts: table)
--- @field path? agentic.ui.FilePicker.FzfPathModule
local FilePicker = {}

FilePicker.CMD_RG = {
    "rg",
    "--files",
    "--color",
    "never",
    "--hidden",
    "--glob",
    "!.git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_FD = {
    "fd",
    "--type",
    "f",
    "--color",
    "never",
    "--hidden",
    "--exclude",
    ".git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_GIT = { "git", "ls-files", "-co", "--exclude-standard" }

--- @return agentic.ui.FilePicker.FzfLua|nil
local function load_fzf_lua()
    local ok, loaded_fzf = pcall(require, "fzf-lua")
    if not ok then
        return nil
    end

    local fzf = loaded_fzf --[[@as agentic.ui.FilePicker.FzfLua]]
    return fzf
end

--- @param path string
--- @return string|nil
local function resolve_file_path(path)
    if path == "" then
        return nil
    end

    local absolute_path = FileSystem.to_absolute_path(path)
    local stat = vim.uv.fs_stat(absolute_path)
    if stat and stat.type == "file" then
        return absolute_path
    end

    return nil
end

--- @param selected string[]|nil
--- @param fzf agentic.ui.FilePicker.FzfLua
--- @return string[]
local function get_fzf_selected_paths(selected, fzf)
    if type(selected) ~= "table" or #selected == 0 then
        return {}
    end

    local fzf_path = fzf.path
    if not fzf_path then
        return {}
    end

    local cwd = vim.uv.cwd() or vim.fn.getcwd()

    --- @type string[]
    local file_paths = {}
    for _, entry in ipairs(selected) do
        if type(entry) == "string" and entry ~= "" then
            local parsed_entry = fzf_path.entry_to_file(entry, { cwd = cwd })
            if parsed_entry.path then
                table.insert(file_paths, parsed_entry.path)
            end
        end
    end

    return file_paths
end

--- @param selected string[]|nil
--- @param on_file_selected fun(file_path: string)|nil
local function add_selected_files(selected, on_file_selected)
    if type(selected) ~= "table" or #selected == 0 then
        return
    end

    for _, path in ipairs(selected) do
        if type(path) == "string" and path ~= "" then
            local absolute_path = resolve_file_path(path)
            if on_file_selected and absolute_path then
                on_file_selected(absolute_path)
            end
        end
    end
end

--- @return table[] commands
local function build_scan_commands()
    local commands = {}

    if vim.fn.executable(FilePicker.CMD_RG[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_RG))
    end

    if vim.fn.executable(FilePicker.CMD_FD[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_FD))
    end

    if vim.fn.executable(FilePicker.CMD_GIT[1]) == 1 then
        local _ = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
        if vim.v.shell_error == 0 then
            table.insert(commands, vim.list_extend({}, FilePicker.CMD_GIT))
        end
    end

    return commands
end

--- @param path string
--- @return boolean
local function should_exclude(path)
    for _, pattern in ipairs(FilePicker.GLOB_EXCLUDE_PATTERNS) do
        if path:match(pattern) then
            return true
        end
    end

    return false
end

--- Returns the 1-based screen row of the top edge of the AgenticInput window
--- in the current tabpage, or nil when no such window exists.
--- @return integer|nil
local function find_agentic_prompt_top_row()
    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "AgenticInput" then
            local screenpos = vim.fn.win_screenpos(winid)
            return screenpos[1]
        end
    end
    return nil
end

--- Build a popup that anchors at the bottom of the editor (above the agentic
--- prompt) so the picker pops upward. Results and preview sit side-by-side on
--- top, with the fzf input line at the bottom of the picker.
--- @return table
local function build_fzf_winopts()
    local lines = vim.o.lines
    local cmdheight = vim.o.cmdheight or 1
    local prompt_top_row = find_agentic_prompt_top_row()

    -- Bottom edge of the picker (1-based screen row, inclusive). Leave a
    -- single-row gap above the prompt so its border stays visible.
    local picker_bottom_row = prompt_top_row and (prompt_top_row - 2)
        or (lines - cmdheight)

    -- Height accounts for the rounded border (top + bottom = 2 rows).
    local available_height = math.max(picker_bottom_row, 1)
    local picker_height = math.max(15, math.min(available_height, 25))
    local picker_top_row = math.max(0, picker_bottom_row - picker_height)

    return {
        relative = "editor",
        row = picker_top_row,
        col = 0,
        width = 1,
        height = picker_height,
        backdrop = 100,
        preview = {
            layout = "horizontal",
        },
    }
end

--- @param on_file_selected fun(file_path: string)|nil
--- @param on_complete fun()|nil
function FilePicker.open(on_file_selected, on_complete)
    local file_picker_enabled = Config.file_picker.enabled --[[@as boolean]]
    if not file_picker_enabled then
        return
    end

    local fzf = load_fzf_lua()
    if fzf and type(fzf.files) == "function" then
        local completed = false
        local function complete_once()
            if completed then
                return
            end
            completed = true

            if on_complete then
                on_complete()
            end
        end

        local winopts = build_fzf_winopts()
        -- Restore the prompt only after the picker fully closes so accept and
        -- cancel share the same mode handoff.
        winopts.on_close = complete_once

        fzf.files({
            file_icons = false,
            winopts = winopts,
            -- Place fzf's input line at the bottom of the picker so results
            -- grow upward toward the preview pane.
            fzf_opts = {
                ["--layout"] = "reverse-list",
            },
            actions = {
                ["default"] = function(selected)
                    local selected_paths = selected
                    if
                        fzf.path
                        and type(fzf.path.entry_to_file) == "function"
                    then
                        selected_paths = get_fzf_selected_paths(selected, fzf)
                    end

                    add_selected_files(selected_paths, on_file_selected)
                end,
            },
        })
        return
    end

    local files = FilePicker.scan_files()
    local items = vim.tbl_map(function(file)
        return file.word:gsub("^@", "")
    end, files)
    vim.ui.select(items, {
        prompt = "Select file to attach:",
    }, function(selected)
        if selected then
            add_selected_files({ selected }, on_file_selected)
        end
        if on_complete then
            on_complete()
        end
    end)
end

function FilePicker.scan_files()
    local commands = build_scan_commands()

    -- Try each command until one succeeds
    for _, cmd_parts in ipairs(commands) do
        Logger.debug("[FilePicker] Trying command:", vim.inspect(cmd_parts))
        local start_time = vim.loop.hrtime()

        local output = vim.fn.system(cmd_parts)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6

        Logger.debug(
            string.format(
                "[FilePicker] Command completed in %.2fms, exit_code: %d",
                elapsed,
                vim.v.shell_error
            )
        )

        if vim.v.shell_error == 0 and output ~= "" then
            local files = {}
            for line in output:gmatch("[^\n]+") do
                if line ~= "" then
                    local relative_path = FileSystem.to_smart_path(line)
                    table.insert(files, {
                        word = "@" .. relative_path,
                        menu = "File",
                        kind = "@",
                        icase = 1,
                    })
                end
            end

            table.sort(files, function(a, b)
                return a.word < b.word
            end)

            return files
        end
    end

    -- Fallback to glob if all commands failed
    Logger.debug("[FilePicker] All commands failed, using glob fallback")
    local files = {}
    local seen = {}
    -- Get all files including hidden files (dotfiles) and files inside hidden directories
    -- Note: vim.fn.glob() doesn't support brace expansion, so we need separate calls
    local glob_files = vim.fn.glob("**/*", false, true) -- Regular files
    local hidden_files = vim.fn.glob("**/.*", false, true) -- Dotfiles at any depth
    local files_in_hidden = vim.fn.glob("**/.*/**/*", false, true) -- Files inside dot dirs
    vim.list_extend(glob_files, hidden_files)
    vim.list_extend(glob_files, files_in_hidden)
    Logger.debug("[FilePicker] Glob returned", #glob_files, "paths")

    for _, path in ipairs(glob_files) do
        if vim.fn.isdirectory(path) == 0 and not should_exclude(path) then
            local relative_path = FileSystem.to_smart_path(path)
            if not seen[relative_path] then
                seen[relative_path] = true
                table.insert(files, {
                    word = "@" .. relative_path,
                    menu = "File",
                    kind = "@",
                    icase = 1,
                })
            end
        end
    end

    table.sort(files, function(a, b)
        return a.word < b.word
    end)

    return files
end

--- used exclusively with glob fallback to exclude common unwanted files
FilePicker.GLOB_EXCLUDE_PATTERNS = {
    "^%.$",
    "^%.%.$",
    "%.git/",
    "^%.git$", -- Exclude .git (both directory and file used in worktrees)
    "%.DS_Store$",
    "node_modules/",
    "%.pyc$",
    "%.swp$",
    "__pycache__/",
    "dist/",
    "build/",
    "vendor/",
    "%.next/",
    -- Java/JVM
    "target/",
    "%.gradle/",
    "%.m2/",
    -- Ruby
    "%.bundle/",
    -- Build/Cache
    "%.cache/",
    "%.turbo/",
    "/out/", -- Build output directory (anchored to avoid matching "layout/")
    -- Coverage
    "coverage/",
    "%.nyc_output/",
    -- Package managers
    "%.npm/",
    "%.yarn/",
    "%.pnpm%-store/",
    "bower_components/",
}

return FilePicker
