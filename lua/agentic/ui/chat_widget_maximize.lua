local Logger = require("agentic.utils.logger")
local WidgetLayout = require("agentic.ui.widget_layout")

local M = {}

--- @class agentic.ui.ChatWidgetMaximize.AttachOpts
--- @field AGENTIC_FILETYPES table<string, boolean|nil>
--- @field CYCLE_ORDER agentic.ui.ChatWidget.PanelNames[]

--- Window-local editor options to preserve when a widget window is reused
--- as part of the restored editor layout.
--- @type string[]
local EDITOR_WINDOW_OPTS = {
    "statuscolumn",
    "signcolumn",
    "number",
    "numberwidth",
    "relativenumber",
    "foldcolumn",
    "wrap",
    "linebreak",
    "cursorline",
    "cursorcolumn",
    "list",
    "colorcolumn",
    "conceallevel",
    "concealcursor",
    "spell",
    "winhl",
    "winfixheight",
    "winfixwidth",
}

--- @param node agentic.ui.ChatWidget.MaximizeNode
--- @return integer count
local function count_widget_nodes(node)
    if node.kind == "widget" then
        return 1
    end

    if node.kind == "leaf" then
        return 0
    end

    local count = 0
    local children = node.children or {}
    for _, child in ipairs(children) do
        count = count + count_widget_nodes(child)
    end
    return count
end

--- @param node agentic.ui.ChatWidget.MaximizeNode
--- @return integer count
local function count_editor_leaves(node)
    if node.kind == "leaf" then
        return 1
    end

    if node.kind == "widget" then
        return 0
    end

    local count = 0
    local children = node.children or {}
    for _, child in ipairs(children) do
        count = count + count_editor_leaves(child)
    end
    return count
end

--- @param node agentic.ui.ChatWidget.MaximizeNode
--- @return integer|nil leaf_id
local function first_editor_leaf_id(node)
    if node.kind == "leaf" then
        return node.leaf_id
    end

    if node.kind == "widget" then
        return nil
    end

    local children = node.children or {}
    for _, child in ipairs(children) do
        local leaf_id = first_editor_leaf_id(child)
        if leaf_id then
            return leaf_id
        end
    end

    return nil
end

--- @param children agentic.ui.ChatWidget.MaximizeNode[]
--- @param kind "row"|"col"
--- @return integer width
--- @return integer height
local function compute_container_size(children, kind)
    local width = 0
    local height = 0

    for _, child in ipairs(children) do
        if kind == "row" then
            width = width + child.width
            height = math.max(height, child.height)
        else
            width = math.max(width, child.width)
            height = height + child.height
        end
    end

    return width, height
end

--- @param winid integer
--- @return table<string, boolean|integer|string> win_opts
local function capture_window_options(winid)
    --- @type table<string, boolean|integer|string>
    local win_opts = {}

    for _, option_name in ipairs(EDITOR_WINDOW_OPTS) do
        win_opts[option_name] =
            vim.api.nvim_get_option_value(option_name, { win = winid })
    end

    return win_opts
end

--- @param winid integer
--- @param win_opts table<string, boolean|integer|string>
local function restore_window_options(winid, win_opts)
    vim.wo[winid].winfixbuf = false

    for option_name, value in pairs(win_opts) do
        pcall(
            vim.api.nvim_set_option_value,
            option_name,
            value,
            { win = winid }
        )
    end
end

--- @param winid integer
--- @param bufnr integer
local function set_window_buffer(winid, bufnr)
    vim.wo[winid].winfixbuf = false
    if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        vim.api.nvim_win_set_buf(winid, bufnr)
    end
end

--- @param winid integer
--- @param split "right"|"below"
--- @return integer
local function open_restore_split(winid, split)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local new_winid = vim.api.nvim_open_win(bufnr, false, {
        split = split,
        win = winid,
        noautocmd = true,
    })
    vim.wo[new_winid].winfixbuf = false
    return new_winid
end

--- @param tab_page_id integer
local function clear_tab_mirror(tab_page_id)
    if vim.api.nvim_tabpage_is_valid(tab_page_id) then
        pcall(function()
            vim.t[tab_page_id].agentic_maximized_windows = nil
        end)
    end
end

--- @param maximize_state agentic.ui.ChatWidget.MaximizeState
local function restore_bufhidden_overrides(maximize_state)
    for bufnr, original_bufhidden in pairs(maximize_state.bufhidden_overrides) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].bufhidden = original_bufhidden
        end
    end
end

--- @param ChatWidget agentic.ui.ChatWidget
--- @param opts agentic.ui.ChatWidgetMaximize.AttachOpts
function M.attach(ChatWidget, opts)
    local AGENTIC_FILETYPES = opts.AGENTIC_FILETYPES
    local CYCLE_ORDER = opts.CYCLE_ORDER

    --- @return boolean
    function ChatWidget:_is_owner_tab()
        return vim.api.nvim_tabpage_is_valid(self.tab_page_id)
            and vim.api.nvim_get_current_tabpage() == self.tab_page_id
    end

    --- @param winid integer|nil
    --- @return boolean
    function ChatWidget:_is_supported_maximize_window(winid)
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            return false
        end

        if vim.api.nvim_win_get_tabpage(winid) ~= self.tab_page_id then
            return false
        end

        local win_config = vim.api.nvim_win_get_config(winid)
        if win_config.relative ~= "" then
            return false
        end

        local bufnr = vim.api.nvim_win_get_buf(winid)
        if self:_is_widget_buffer(bufnr) then
            return false
        end

        local filetype = vim.bo[bufnr].filetype
        if AGENTIC_FILETYPES[filetype] then
            return false
        end

        local buftype = vim.bo[bufnr].buftype
        if buftype == "terminal" or filetype == "help" or filetype == "man" then
            return false
        end

        return vim.fn.win_gettype(winid) == ""
            and not vim.wo[winid].previewwindow
    end

    --- @return integer|nil
    function ChatWidget:_get_preferred_editor_focus_winid()
        local current_winid = vim.api.nvim_get_current_win()
        if self:_is_supported_maximize_window(current_winid) then
            return current_winid
        end

        local alt_winnr = vim.fn.winnr("#")
        if alt_winnr ~= 0 then
            local alt_winid = vim.fn.win_getid(alt_winnr)
            if self:_is_supported_maximize_window(alt_winid) then
                return alt_winid
            end
        end

        return nil
    end

    --- @return agentic.ui.ChatWidget.MaximizeState|nil
    function ChatWidget:_capture_maximize_state()
        if not self:_is_owner_tab() then
            Logger.debug("Ignoring maximize capture from a non-owner tab")
            return nil
        end

        local info_by_winid = {}
        local tabnr = vim.api.nvim_tabpage_get_number(self.tab_page_id)
        for _, info in ipairs(vim.fn.getwininfo()) do
            if info.tabnr == tabnr then
                info_by_winid[info.winid] = info
            end
        end

        local preferred_focus_winid = self:_get_preferred_editor_focus_winid()
        local leaves = {}
        local next_leaf_id = 0
        local focused_leaf_id = nil

        --- @param raw_node any[]
        --- @return agentic.ui.ChatWidget.MaximizeNode|nil
        --- @return string|nil
        local function capture_node(raw_node)
            local kind = raw_node[1]

            if kind == "leaf" then
                local winid = raw_node[2]
                if not vim.api.nvim_win_is_valid(winid) then
                    return nil, "invalid window in winlayout()"
                end

                local bufnr = vim.api.nvim_win_get_buf(winid)
                local info = info_by_winid[winid]
                if not info then
                    return nil,
                        "missing getwininfo() entry for window " .. tostring(
                            winid
                        )
                end

                if self:_is_widget_buffer(bufnr) then
                    --- @type agentic.ui.ChatWidget.MaximizeWidgetState
                    local widget_node = {
                        kind = "widget",
                        width = info.width,
                        height = info.height,
                    }
                    return widget_node
                end

                local filetype = vim.bo[bufnr].filetype
                if AGENTIC_FILETYPES[filetype] then
                    return nil,
                        "cross-tab Agentic buffers cannot participate in maximize restore"
                end

                if not self:_is_supported_maximize_window(winid) then
                    return nil,
                        string.format(
                            "unsupported special window for maximize restore: type=%s buftype=%s filetype=%s",
                            vim.fn.win_gettype(winid),
                            vim.bo[bufnr].buftype,
                            filetype
                        )
                end

                next_leaf_id = next_leaf_id + 1
                local leaf_id = next_leaf_id
                if preferred_focus_winid == winid then
                    focused_leaf_id = leaf_id
                end

                local view = vim.api.nvim_win_call(winid, function()
                    return vim.fn.winsaveview()
                end)

                --- @type agentic.ui.ChatWidget.MaximizeLeafState
                local leaf_node = {
                    kind = "leaf",
                    leaf_id = leaf_id,
                    bufnr = bufnr,
                    width = info.width,
                    height = info.height,
                    view = view,
                    win_opts = capture_window_options(winid),
                }
                leaves[leaf_id] = leaf_node
                return leaf_node
            end

            --- @type agentic.ui.ChatWidget.MaximizeNode[]
            local children = {}
            for _, child in ipairs(raw_node[2]) do
                local child_node, err = capture_node(child)
                if err then
                    return nil, err
                end
                if child_node then
                    table.insert(children, child_node)
                end
            end

            if #children == 0 then
                return nil
            end

            local only_widget = true
            for _, child in ipairs(children) do
                if child.kind ~= "widget" then
                    only_widget = false
                    break
                end
            end

            local width, height = compute_container_size(children, kind)
            if only_widget then
                --- @type agentic.ui.ChatWidget.MaximizeWidgetState
                local widget_node = {
                    kind = "widget",
                    width = width,
                    height = height,
                }
                return widget_node
            end

            if #children == 1 then
                return children[1]
            end

            --- @type agentic.ui.ChatWidget.MaximizeContainerState
            local container = {
                kind = kind,
                width = width,
                height = height,
                children = children,
            }
            return container
        end

        local layout, err = capture_node(vim.fn.winlayout())
        if err then
            Logger.notify(
                "Cannot maximize Agentic in this tab: " .. err,
                vim.log.levels.WARN,
                { title = "Agentic: maximize" }
            )
            return nil
        end

        if not layout or count_editor_leaves(layout) == 0 then
            return nil
        end

        if count_widget_nodes(layout) ~= 1 then
            Logger.notify(
                "Cannot maximize Agentic: widget layout is not restorable in this tab.",
                vim.log.levels.WARN,
                { title = "Agentic: maximize" }
            )
            return nil
        end

        if not focused_leaf_id then
            focused_leaf_id = first_editor_leaf_id(layout)
        end

        --- @type agentic.ui.ChatWidget.MaximizeState
        local maximize_state = {
            layout = layout,
            leaves = leaves,
            focused_leaf_id = focused_leaf_id,
            bufhidden_overrides = {},
        }
        return maximize_state
    end

    --- @return integer|nil
    function ChatWidget:_prepare_maximize_restore_root()
        if not self:_is_owner_tab() then
            return nil
        end

        local current_winid = vim.api.nvim_get_current_win()
        local root_winid = nil
        if vim.api.nvim_win_is_valid(current_winid) then
            local current_bufnr = vim.api.nvim_win_get_buf(current_winid)
            if self:_is_widget_buffer(current_bufnr) then
                root_winid = current_winid
            end
        end

        if not root_winid then
            for _, panel_name in ipairs(CYCLE_ORDER) do
                local winid = self.win_nrs[panel_name]
                if winid ~= nil and vim.api.nvim_win_is_valid(winid) then
                    root_winid = winid
                    break
                end
            end
        end

        if not root_winid then
            for _, winid in
                ipairs(vim.api.nvim_tabpage_list_wins(self.tab_page_id))
            do
                local bufnr = vim.api.nvim_win_get_buf(winid)
                if self:_is_widget_buffer(bufnr) then
                    root_winid = winid
                    break
                end
            end
        end

        if not root_winid then
            return nil
        end

        local was_hiding = self._is_hiding == true
        self._is_hiding = true
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(self.tab_page_id)) do
            if winid ~= root_winid then
                pcall(vim.api.nvim_win_close, winid, true)
            end
        end
        self._is_hiding = was_hiding

        for name, _ in pairs(self.win_nrs) do
            self.win_nrs[name] = nil
        end

        vim.wo[root_winid].winfixbuf = false
        vim.wo[root_winid].winfixheight = false
        vim.wo[root_winid].winfixwidth = false
        return root_winid
    end

    --- @param keep_widget boolean
    --- @return boolean restored
    function ChatWidget:_restore_maximize_state(keep_widget)
        local maximize_state = self._maximize_state
        if not maximize_state or not self:_is_owner_tab() then
            return false
        end

        local root_winid = self:_prepare_maximize_restore_root()
        if not root_winid then
            return false
        end

        --- @type table<integer, integer>
        local leaf_wins = {}
        --- @type integer|nil
        local widget_placeholder_winid = nil

        --- @param node agentic.ui.ChatWidget.MaximizeNode
        --- @param winid integer
        local function restore_node(node, winid)
            if node.kind == "leaf" then
                local leaf = node --[[@as agentic.ui.ChatWidget.MaximizeLeafState]]
                if not vim.api.nvim_buf_is_valid(leaf.bufnr) then
                    error("saved buffer was deleted: " .. tostring(leaf.bufnr))
                end

                set_window_buffer(winid, leaf.bufnr)
                restore_window_options(winid, leaf.win_opts)
                leaf_wins[leaf.leaf_id] = winid
                return
            end

            if node.kind == "widget" then
                set_window_buffer(winid, self.buf_nrs.chat)
                widget_placeholder_winid = winid
                return
            end

            local children = node.children or {}
            local split = node.kind == "row" and "right" or "below"
            local child_wins = { winid }

            for index = 2, #children do
                local previous_winid = child_wins[index - 1]
                if previous_winid then
                    child_wins[index] =
                        open_restore_split(previous_winid, split)
                end
            end

            for index, child in ipairs(children) do
                local child_winid = child_wins[index]
                if child_winid then
                    restore_node(child, child_winid)
                end
            end

            if node.kind == "row" then
                for index = 1, #children - 1 do
                    local child_winid = child_wins[index]
                    local child = children[index]
                    if child_winid and child then
                        pcall(
                            vim.api.nvim_win_set_width,
                            child_winid,
                            child.width
                        )
                    end
                end
            else
                for index = 1, #children - 1 do
                    local child_winid = child_wins[index]
                    local child = children[index]
                    if child_winid and child then
                        pcall(
                            vim.api.nvim_win_set_height,
                            child_winid,
                            child.height
                        )
                    end
                end
            end
        end

        local ok, err = pcall(function()
            restore_node(maximize_state.layout, root_winid)
        end)
        if not ok or not widget_placeholder_winid then
            Logger.notify(
                "Failed to restore Agentic maximize layout: "
                    .. tostring(err or "missing widget placeholder"),
                vim.log.levels.WARN,
                { title = "Agentic: maximize restore" }
            )
            return false
        end

        for name, _ in pairs(self.win_nrs) do
            self.win_nrs[name] = nil
        end
        self.win_nrs.chat = widget_placeholder_winid
        set_window_buffer(widget_placeholder_winid, self.buf_nrs.chat)

        if keep_widget then
            self:show({ focus_prompt = false })
        else
            local was_hiding = self._is_hiding == true
            self._is_hiding = true
            WidgetLayout.close(self.win_nrs)
            self._is_hiding = was_hiding
        end

        for leaf_id, leaf in pairs(maximize_state.leaves) do
            local winid = leaf_wins[leaf_id]
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_call(winid, function()
                    pcall(vim.fn.winrestview, leaf.view)
                end)
            end
        end

        local focused_leaf_id = maximize_state.focused_leaf_id
        local focused_winid = focused_leaf_id and leaf_wins[focused_leaf_id]
            or nil
        if focused_winid and vim.api.nvim_win_is_valid(focused_winid) then
            vim.api.nvim_set_current_win(focused_winid)
        end

        return true
    end

    --- @param reason string
    --- @param clear_opts { restore_layout?: boolean, keep_widget?: boolean }|nil
    --- @return boolean restored
    function ChatWidget:_clear_maximize_state(reason, clear_opts)
        local maximize_state = self._maximize_state
        if not maximize_state then
            clear_tab_mirror(self.tab_page_id)
            return false
        end

        clear_opts = clear_opts or {}
        local restored = false

        if clear_opts.restore_layout then
            restored =
                self:_restore_maximize_state(clear_opts.keep_widget == true)
            if not restored and self:_is_owner_tab() then
                Logger.notify(
                    "Failed to restore Agentic maximize state during "
                        .. reason
                        .. ".",
                    vim.log.levels.WARN,
                    { title = "Agentic: maximize restore" }
                )
            end
        end

        restore_bufhidden_overrides(maximize_state)
        self._maximize_state = nil
        clear_tab_mirror(self.tab_page_id)

        return restored
    end

    --- Toggle maximize: close editor windows or restore them
    function ChatWidget:_toggle_full_width()
        if not self:_is_owner_tab() then
            Logger.debug("Ignoring maximize toggle from a non-owner tab")
            return
        end

        if self._maximize_state then
            self:_clear_maximize_state("toggle", {
                restore_layout = true,
                keep_widget = true,
            })
            return
        end

        local maximize_state = self:_capture_maximize_state()
        if not maximize_state then
            return
        end

        self._maximize_state = maximize_state

        local ok, err = pcall(function()
            for _, winid in
                ipairs(vim.api.nvim_tabpage_list_wins(self.tab_page_id))
            do
                if self:_is_supported_maximize_window(winid) then
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    local bufhidden = vim.bo[bufnr].bufhidden

                    if
                        (bufhidden == "wipe" or bufhidden == "delete")
                        and maximize_state.bufhidden_overrides[bufnr] == nil
                    then
                        maximize_state.bufhidden_overrides[bufnr] = bufhidden
                        vim.bo[bufnr].bufhidden = "hide"
                    end

                    vim.api.nvim_win_close(winid, true)
                end
            end
        end)

        if not ok then
            restore_bufhidden_overrides(maximize_state)
            self._maximize_state = nil
            Logger.notify(
                "Failed to maximize Agentic layout: " .. tostring(err),
                vim.log.levels.WARN,
                { title = "Agentic: maximize" }
            )
        end
    end
end

return M
