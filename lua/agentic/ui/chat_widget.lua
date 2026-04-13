local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"

--- Filetypes used by widget buffers. Used to detect cross-tabpage widget
--- buffers that don't belong to the current widget instance (since
--- `_is_widget_buffer` only knows about its own `buf_nrs`).
local AGENTIC_FILETYPES = {
    AgenticChat = true,
    AgenticInput = true,
    AgenticTodos = true,
    AgenticCode = true,
    AgenticFiles = true,
    AgenticDiagnostics = true,
}

--- Ordered list of panels for window cycling
--- @type agentic.ui.ChatWidget.PanelNames[]
--- Panels that are not user-attached content (excluded from "has other content" checks)
local NON_CONTENT_PANELS = {
    chat = true,
    input = true,
    todos = true,
} --- @type table<agentic.ui.ChatWidget.PanelNames, boolean>

--- Ordered list of panels for window cycling
--- @type agentic.ui.ChatWidget.PanelNames[]
local CYCLE_ORDER = { "chat", "todos", "code", "files", "diagnostics", "input" }

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field suffix? string Context help text

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- Options for controlling widget display behavior
--- @class agentic.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- Options for showing the widget
--- @class agentic.ui.ChatWidget.ShowOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean Automatically add current selection or file to context when opening

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class agentic.ui.ChatWidget
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field on_submit_input fun(prompt: string) external callback to be called when user submits the input
--- @field message_writer? agentic.ui.MessageWriter
--- @field _on_before_hide? fun()
--- @field _on_after_show? fun(chat_winid: integer|nil)
--- @field _is_hiding? boolean
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @param tab_page_id integer
--- @param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    self = setmetatable({}, self)

    self.win_nrs = {}
    self.current_position = Config.windows.position

    self.on_submit_input = on_submit_input
    self.tab_page_id = tab_page_id

    self:_initialize()
    self:_bind_events_to_change_headers()

    return self
end

function ChatWidget:is_open()
    local win_id = self.win_nrs.chat
    return (win_id and vim.api.nvim_win_is_valid(win_id)) or false
end

--- Check if the cursor is currently in one of the widget's buffers
--- @return boolean
function ChatWidget:is_cursor_in_widget()
    if not self:is_open() then
        return false
    end

    return self:_is_widget_buffer(vim.api.nvim_get_current_buf())
end

--- @param callback fun()|nil
function ChatWidget:set_on_before_hide(callback)
    self._on_before_hide = callback
end

--- @param callback fun(chat_winid: integer|nil)|nil
function ChatWidget:set_on_after_show(callback)
    self._on_after_show = callback
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function ChatWidget:show(opts)
    opts = opts or {}

    WidgetLayout.open({
        tab_page_id = self.tab_page_id,
        buf_nrs = self.buf_nrs,
        win_nrs = self.win_nrs,
        focus_prompt = opts.focus_prompt,
        position = self.current_position,
    })

    if self._on_after_show then
        self._on_after_show(self.win_nrs.chat)
    end
end

--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function ChatWidget:rotate_layout(layouts)
    if not layouts or #layouts == 0 then
        layouts = { "right", "bottom", "left" }
    end

    if #layouts == 1 then
        Logger.notify(
            "Only one layout defined for rotation, it'll always show the same: "
                .. layouts[1],
            vim.log.levels.WARN,
            { title = "Agentic: rotate layout" }
        )
    end

    local current = self.current_position
    local next_layout = layouts[1]

    for i, layout in ipairs(layouts) do
        if layout == current then
            local next_index = i % #layouts + 1
            if layouts[next_index] then
                next_layout = layouts[next_index]
            end
            break
        end
    end

    self.current_position = next_layout

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    self:hide()
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        local win = vim.fn.bufwinid(previous_buf)
        if win ~= -1 then
            vim.api.nvim_set_current_win(win)
        end
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    if self._is_hiding or not self:is_open() then
        return
    end

    self._is_hiding = true

    local ok, err = xpcall(function()
        vim.cmd("stopinsert")

        if self._on_before_hide then
            self._on_before_hide()
        end

        -- Check if we're on the correct tabpage before trying to find/create fallback window
        local current_tabpage = vim.api.nvim_get_current_tabpage()
        local should_create_fallback = current_tabpage == self.tab_page_id

        if should_create_fallback then
            local fallback_winid = self:find_first_non_widget_window()

            if not fallback_winid then
                -- Fallback: create a new left window to avoid closing the last window error
                local created_winid = self:open_left_window()
                if not created_winid then
                    Logger.notify(
                        "Failed to create fallback window; cannot hide widget safely, run `:tabclose` to close the tab instead.",
                        vim.log.levels.ERROR
                    )
                    return
                end
            end
        end

        WidgetLayout.close(self.win_nrs)
    end, debug.traceback)

    self._is_hiding = false

    if not ok then
        error(err)
    end
end

--- Cleans up all buffers content without destroying them
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        BufHelpers.with_modifiable(bufnr, function()
            local ok =
                pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
            if not ok then
                Logger.debug(
                    string.format(
                        "Failed to clear buffer '%s' with id: %d",
                        name,
                        bufnr
                    )
                )
            end
        end)
    end
end

--- Deletes all buffers and removes them from memory
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    self:hide()

    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to delete buffer '%s' with id: %d",
                    name,
                    bufnr
                )
            )
        end
    end
end

function ChatWidget:_submit_input()
    vim.cmd("stopinsert")

    local lines = vim.api.nvim_buf_get_lines(self.buf_nrs.input, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")

    -- Check if prompt is empty or contains only whitespace
    local has_prompt = prompt and prompt ~= "" and prompt:match("%S")

    if not has_prompt then
        -- Allow submit if other content (files, diagnostics, code) is attached
        local has_other_content = false
        for name, bufnr in pairs(self.buf_nrs) do
            if
                not NON_CONTENT_PANELS[name]
                and vim.api.nvim_buf_is_valid(bufnr)
            then
                local buf_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local content = table.concat(buf_lines, "")
                if content:match("%S") then
                    has_other_content = true
                    break
                end
            end
        end

        if not has_other_content then
            return
        end

        prompt = prompt or ""
    end

    vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})

    for name, bufnr in pairs(self.buf_nrs) do
        if not NON_CONTENT_PANELS[name] then
            BufHelpers.with_modifiable(bufnr, function(b)
                vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
            end)
        end
    end

    self.on_submit_input(prompt)

    for name, _ in pairs(self.buf_nrs) do
        if not NON_CONTENT_PANELS[name] then
            self:close_optional_window(name)
        end
    end
    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:move_cursor_to(self.win_nrs.chat)
end

--- @param winid integer|nil
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            if Config.settings.move_cursor_to_chat_on_submit then
                vim.api.nvim_set_current_win(winid)
            end

            -- make sure to scroll to the bottom
            -- 1. user can see the new message
            -- 2. auto-scroll will start again
            vim.api.nvim_win_call(winid, function()
                vim.cmd("normal! G0zb")
            end)

            if callback then
                callback()
            end
        end
    end)
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()

    self:_bind_keymaps()

    -- I only want to trigger a full close of the chat widget when closing the chat or the input buffers, the others are auxiliary
    for _, bufnr in ipairs({
        self.buf_nrs.chat,
        self.buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = bufnr,
            callback = function()
                self:hide()
            end,
        })
    end
end

--- Cycle through widget windows using CYCLE_ORDER
--- @param direction integer 1 for forward, -1 for backward
function ChatWidget:_cycle_windows(direction)
    local current_win = vim.api.nvim_get_current_win()
    local in_insert = vim.fn.mode():sub(1, 1) == "i"
    local len = #CYCLE_ORDER

    -- Find current position in cycle
    local current_idx = nil
    for i, panel_name in ipairs(CYCLE_ORDER) do
        local winid = self.win_nrs[panel_name]
        if winid and winid == current_win then
            current_idx = i
            break
        end
    end

    -- If not in any widget window, start from first (forward) or last (backward)
    if not current_idx then
        current_idx = direction == 1 and 0 or (len + 1)
    end

    -- Find next valid window in the given direction
    for offset = 1, len do
        local next_idx = (current_idx + direction * offset - 1) % len + 1
        local next_panel = CYCLE_ORDER[next_idx]
        local next_winid = self.win_nrs[next_panel]

        if next_winid and vim.api.nvim_win_is_valid(next_winid) then
            if in_insert then
                vim.cmd.stopinsert()
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(next_winid) then
                        vim.api.nvim_set_current_win(next_winid)
                    end
                end)
            else
                vim.api.nvim_set_current_win(next_winid)
            end
            return
        end
    end
end

--- Focus on the prompt (input) window
function ChatWidget:focus_prompt()
    local input_winid = self.win_nrs.input

    if not input_winid or not vim.api.nvim_win_is_valid(input_winid) then
        Logger.notify("Prompt window is not open", vim.log.levels.INFO)
        return
    end

    vim.api.nvim_set_current_win(input_winid)
end

--- Get all line numbers where user prompts start (recorded via extmarks).
--- @return integer[] positions 1-indexed line numbers
function ChatWidget:_get_prompt_positions()
    if not self.message_writer then
        return {}
    end
    return self.message_writer:get_prompt_positions()
end

--- Navigate to next or previous user prompt in chat buffer
--- @param direction "next"|"prev"
function ChatWidget:_navigate_prompt(direction)
    local chat_winid = self.win_nrs.chat
    if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
        -- Fallback: find the window currently showing the chat buffer
        local bufnr = self.buf_nrs.chat
        chat_winid = bufnr and vim.fn.bufwinid(bufnr) or -1
        if chat_winid == -1 then
            Logger.notify("Chat window is not open", vim.log.levels.INFO)
            return
        end
    end

    local positions = self:_get_prompt_positions()
    if #positions == 0 then
        Logger.notify("No prompts found in chat", vim.log.levels.INFO)
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(chat_winid)
    local current_line = cursor[1]

    local current_index = -1
    local is_exactly_on_prompt = false

    for i, pos in ipairs(positions) do
        if pos == current_line then
            current_index = i - 1
            is_exactly_on_prompt = true
            break
        elseif pos < current_line then
            current_index = i - 1
        else
            break
        end
    end

    local new_index
    if direction == "next" then
        new_index = (current_index + 1) % #positions
    else
        if is_exactly_on_prompt then
            new_index = current_index <= 0 and #positions - 1
                or current_index - 1
        else
            new_index = current_index < 0 and #positions - 1 or current_index
        end
    end

    local target_line = positions[new_index + 1]

    vim.api.nvim_win_call(chat_winid, function()
        vim.cmd(string.format("normal! %dGzz", target_line))
    end)
end

--- Navigate to next user prompt
function ChatWidget:navigate_next_prompt()
    self:_navigate_prompt("next")
end

--- Navigate to previous user prompt
function ChatWidget:navigate_prev_prompt()
    self:_navigate_prompt("prev")
end

--- Toggle maximize: close other windows or restore them
function ChatWidget:_toggle_full_width()
    local stored = vim.t[self.tab_page_id].agentic_maximized_windows

    if stored and #stored > 0 then
        -- Restore: re-open or un-minimize the previously saved windows
        vim.t[self.tab_page_id].agentic_maximized_windows = nil

        local restored_any = false
        for _, entry in ipairs(stored) do
            local bufnr = entry.bufnr
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
                    split = "left",
                    win = -1,
                })
                if ok and entry.width then
                    pcall(vim.api.nvim_win_set_width, winid, entry.width)
                end
                if ok then
                    restored_any = true
                    -- Restore original bufhidden if it was overridden
                    if entry.bufhidden then
                        vim.bo[bufnr].bufhidden = entry.bufhidden
                    end
                end
            end
        end

        -- If no windows were restored (e.g. all buffers got wiped),
        -- fall back to opening a usable window
        if not restored_any then
            self:open_left_window()
        end
    else
        -- Maximize: close or minimize all non-widget, non-floating windows
        local all_windows = vim.api.nvim_tabpage_list_wins(self.tab_page_id)

        local widget_buf_ids = {}
        for _, bufnr in pairs(self.buf_nrs) do
            if bufnr then
                widget_buf_ids[bufnr] = true
            end
        end

        --- @type { bufnr: integer|nil, width: integer, bufhidden: string|nil }[]
        local to_restore = {}
        for _, winid in ipairs(all_windows) do
            local win_buf = vim.api.nvim_win_get_buf(winid)
            -- Skip this widget's own buffers AND any cross-tabpage widget
            -- buffers (detected by filetype) so they are never saved/closed.
            if
                not widget_buf_ids[win_buf]
                and not AGENTIC_FILETYPES[vim.bo[win_buf].filetype]
            then
                local win_config = vim.api.nvim_win_get_config(winid)
                -- Only affect non-floating windows (skip notifications, popups, etc.)
                if win_config.relative == "" then
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    local width = vim.api.nvim_win_get_width(winid)
                    local bufhidden = vim.bo[bufnr].bufhidden

                    if bufhidden == "wipe" or bufhidden == "delete" then
                        -- Temporarily set bufhidden to "hide" so closing the
                        -- window preserves the buffer for later restoration
                        vim.bo[bufnr].bufhidden = "hide"
                        table.insert(to_restore, {
                            bufnr = bufnr,
                            width = width,
                            bufhidden = bufhidden,
                        })
                    else
                        table.insert(to_restore, {
                            bufnr = bufnr,
                            width = width,
                        })
                    end
                    pcall(vim.api.nvim_win_close, winid, true)
                end
            end
        end

        vim.t[self.tab_page_id].agentic_maximized_windows = to_restore
    end
end

function ChatWidget:_bind_keymaps()
    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        self.buf_nrs.input,
        function()
            self:_submit_input()
        end,
        { desc = "Agentic: Submit prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.paste_image,
        self.buf_nrs.input,
        function()
            vim.schedule(function()
                local Clipboard = require("agentic.ui.clipboard")
                local res = Clipboard.paste_image()

                if res ~= nil then
                    -- call vim.paste directly to avoid coupling to the file list logic
                    vim.paste({ res }, -1)
                end
            end)
        end,
        { desc = "Agentic: Paste image from clipboard" }
    )

    for _, bufnr in pairs(self.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.close,
            bufnr,
            function()
                self:hide()
            end,
            { desc = "Agentic: Close Chat widget" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_provider,
            bufnr,
            function()
                require("agentic").switch_provider()
            end,
            { desc = "Agentic: Switch provider" }
        )

        -- Tab to cycle through windows
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.cycle_windows,
            bufnr,
            function()
                self:_cycle_windows(1)
            end,
            { desc = "Agentic: Cycle through windows" }
        )

        -- Shift-Tab to cycle backwards through windows
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.cycle_windows_reverse,
            bufnr,
            function()
                self:_cycle_windows(-1)
            end,
            { desc = "Agentic: Cycle through windows (reverse)" }
        )
    end

    -- Add keybindings to chat, todos, code, and files buffers to jump back to input and start insert mode
    for panel_name, bufnr in pairs(self.buf_nrs) do
        if panel_name ~= "input" then
            for _, key in ipairs({
                "a",
                "A",
                "o",
                "O",
                "i",
                "I",
                "c",
                "C",
            }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    self:move_cursor_to(
                        self.win_nrs.input,
                        BufHelpers.start_insert_on_last_char
                    )
                end)
            end
        end
    end

    -- Add 'x' keymap only to chat buffer to toggle maximize
    BufHelpers.keymap_set(self.buf_nrs.chat, "n", "x", function()
        self:_toggle_full_width()
    end, { desc = "Agentic: Toggle maximize" })

    -- Add prompt navigation keymaps to chat buffer
    BufHelpers.keymap_set(
        self.buf_nrs.chat,
        "n",
        Config.keymaps.chat_navigation.next_prompt,
        function()
            self:navigate_next_prompt()
        end,
        { desc = "Agentic: Navigate to next prompt" }
    )

    BufHelpers.keymap_set(
        self.buf_nrs.chat,
        "n",
        Config.keymaps.chat_navigation.prev_prompt,
        function()
            self:navigate_prev_prompt()
        end,
        { desc = "Agentic: Navigate to previous prompt" }
    )

    DiffPreview.setup_diff_navigation_keymaps(self.buf_nrs)
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    local chat = self:_create_new_buf({
        filetype = "AgenticChat",
    })

    local todos = self:_create_new_buf({
        filetype = "AgenticTodos",
    })

    local code = self:_create_new_buf({
        filetype = "AgenticCode",
    })

    local files = self:_create_new_buf({
        filetype = "AgenticFiles",
    })

    local diagnostics = self:_create_new_buf({
        filetype = "AgenticDiagnostics",
    })

    local input = self:_create_new_buf({
        filetype = "AgenticInput",
        modifiable = true,
    })

    -- Don't call it for the chat buffer as its managed somewhere else
    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, diagnostics, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        diagnostics = diagnostics,
        input = input,
    }

    return buf_nrs
end

--- @param opts table<string, any>
--- @return integer bufnr
function ChatWidget:_create_new_buf(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)

    local config = vim.tbl_deep_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        buflisted = false,
        modifiable = false,
    }, opts)

    for key, value in pairs(config) do
        vim.api.nvim_set_option_value(key, value, { buf = bufnr })
    end

    -- Guard against external plugins/autocommands re-listing agentic buffers
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            vim.bo[bufnr].buflisted = false
        end,
    })

    if opts.filetype then
        local filetype = opts.filetype
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("set filetype=" .. filetype)
        end)
    end

    return bufnr
end

--- @param keymaps  agentic.UserConfig.KeymapValue
--- @param mode string
local function find_keymap(keymaps, mode)
    if type(keymaps) == "string" then
        return keymaps
    end

    for _, keymap in ipairs(keymaps) do
        if type(keymap) == "string" and mode == "n" then
            return keymap
        elseif type(keymap) == "table" then
            if keymap.mode == mode then
                return keymap[1]
            end

            if type(keymap.mode) == "table" then
                ---@diagnostic disable-next-line: param-type-mismatch
                for _, m in ipairs(keymap.mode) do
                    if m == mode then
                        return keymap[1]
                    end
                end
            end
        end
    end
end

--- Binds events to change the suffix header texts based on current mode keymaps
--- For the Chat and Input buffers only
function ChatWidget:_bind_events_to_change_headers()
    local tab_page_id = self.tab_page_id

    for _, bufnr in ipairs({ self.buf_nrs.chat, self.buf_nrs.input }) do
        vim.api.nvim_create_autocmd("ModeChanged", {
            buffer = bufnr,
            callback = function()
                vim.schedule(function()
                    -- Check if tabpage is still valid before accessing vim.t
                    -- I couldn't test it, it seems to only happen from command -> normal, not from insert -> normal
                    if not vim.api.nvim_tabpage_is_valid(tab_page_id) then
                        return
                    end

                    -- Get headers from tabpage-local storage (must reassign after modification)
                    local headers =
                        WindowDecoration.get_headers_state(tab_page_id)

                    local mode = vim.fn.mode()
                    local change_mode_key =
                        find_keymap(Config.keymaps.widget.change_mode, mode)

                    if change_mode_key ~= nil then
                        headers.chat.suffix =
                            string.format("%s: change mode", change_mode_key)
                    else
                        headers.chat.suffix = nil
                    end

                    local submit_key =
                        find_keymap(Config.keymaps.prompt.submit, mode)

                    if submit_key ~= nil then
                        headers.input.suffix =
                            string.format("%s: submit", submit_key)
                    else
                        headers.input.suffix = nil
                    end

                    -- Reassign to persist changes
                    WindowDecoration.set_headers_state(tab_page_id, headers)

                    self:render_header("chat")
                    self:render_header("input")
                end)
            end,
        })
    end
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:render_header(window_name, context)
    local bufnr = self.buf_nrs[window_name]
    if not bufnr then
        return
    end

    WindowDecoration.render_header(bufnr, window_name, context)
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
function ChatWidget:close_optional_window(panel_name)
    WidgetLayout.close_optional_window(
        self.win_nrs,
        panel_name,
        self.current_position
    )
end

--- Filetypes that should be excluded when finding fallback windows
local EXCLUDED_FILETYPES = {
    -- File explorers
    ["neo-tree"] = true,
    ["NvimTree"] = true,
    ["oil"] = true,
    -- Neovim special buffers
    ["qf"] = true, -- Quickfix
    ["help"] = true, -- Help buffers
    ["man"] = true, -- Man pages
    ["terminal"] = true, -- Terminal buffers
    -- Plugin special windows
    ["TelescopePrompt"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFileHistory"] = true,
    ["fugitive"] = true,
    ["gitcommit"] = true,
    ["dashboard"] = true,
    ["alpha"] = true, -- Alpha dashboard
    ["starter"] = true, -- Mini.starter
    ["notify"] = true, -- nvim-notify
    ["noice"] = true, -- Noice popup
    ["aerial"] = true, -- Aerial outline
    ["Outline"] = true, -- symbols-outline
    ["trouble"] = true, -- Trouble diagnostics
    ["spectre_panel"] = true, -- nvim-spectre
    ["lazy"] = true, -- Lazy plugin manager
    ["mason"] = true, -- Mason installer
}

--- Finds the first window on the current tabpage that is NOT part of the chat widget.
--- Prefers windows with non-excluded filetypes (regular editor buffers),
--- but falls back to any non-widget, non-floating window (e.g. dashboard)
--- to avoid creating unnecessary scratch buffers.
--- @return number|nil winid The first non-widget window ID, or nil if none found
function ChatWidget:find_first_non_widget_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.tab_page_id)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(self.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    --- @type number|nil
    local fallback_winid = nil

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            -- Skip floating windows (notifications, popups, etc.)
            local win_config = vim.api.nvim_win_get_config(winid)
            if win_config.relative == "" then
                local bufnr = vim.api.nvim_win_get_buf(winid)
                local ft = vim.bo[bufnr].filetype
                -- Always skip windows showing any Agentic buffer (including
                -- cross-tabpage widget buffers not in this instance's buf_nrs)
                if AGENTIC_FILETYPES[ft] then
                    -- skip entirely, not even as fallback
                elseif not EXCLUDED_FILETYPES[ft] then
                    -- Preferred: a regular editor window
                    return winid
                elseif not fallback_winid then
                    -- Remember as fallback (e.g. dashboard window)
                    fallback_winid = winid
                end
            end
        end
    end

    return fallback_winid
end

--- Checks if a buffer belongs to this widget
--- @param bufnr number
--- @return boolean
function ChatWidget:_is_widget_buffer(bufnr)
    for _, widget_bufnr in pairs(self.buf_nrs) do
        if widget_bufnr == bufnr then
            return true
        end
    end
    return false
end

--- Opens a new window on the left side with full height
--- @param bufnr number|nil The buffer to display in the new window
--- @return number|nil winid The newly created window ID or nil on failure
function ChatWidget:open_left_window(bufnr)
    if bufnr == nil then
        -- Try alternate buffer first, but skip if it's a widget buffer or excluded filetype.
        -- Also skip cross-tabpage widget buffers via filetype check (since
        -- _is_widget_buffer only knows about this instance's buf_nrs).
        local alt_bufnr = vim.fn.bufnr("#")
        if
            alt_bufnr ~= -1
            and vim.api.nvim_buf_is_valid(alt_bufnr)
            and not self:_is_widget_buffer(alt_bufnr)
        then
            local ft = vim.bo[alt_bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] and not AGENTIC_FILETYPES[ft] then
                bufnr = alt_bufnr
            end
        end
    end

    -- Last resort: create new scratch buffer
    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
        split = "left",
        win = -1,
    })

    if not ok then
        Logger.notify(
            "Failed to open window: " .. tostring(winid),
            vim.log.levels.WARN
        )
        return nil
    end

    return winid
end

return ChatWidget
