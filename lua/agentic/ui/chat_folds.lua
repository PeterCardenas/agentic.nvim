local Config = require("agentic.config")
local ExtmarkBlock = require("agentic.utils.extmark_block")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")

--- Fold text prefix stored per-buffer via vim.b variable
local FOLD_TEXT_PREFIXES_VAR = "_agentic_fold_text_prefixes"

--- @class agentic.ui.ChatFolds.ToolCallFold
--- @field tool_call_id string
--- @field should_render_fold? boolean
--- @field default_closed? boolean
--- @field last_known_fold_state? boolean true = closed, false = open
--- @field fold_text_prefix? string

--- @class agentic.ui.ChatFolds.FoldingConfig
--- @field enabled boolean
--- @field closed_by_default boolean
--- @field min_lines integer
--- @field kinds? table<string, agentic.UserConfig.FoldingToolCallKindConfig>

--- @class agentic.ui.ChatFolds
--- @field _bufnr integer
--- @field _tab_page_id integer
--- @field _tool_call_folds table<string, agentic.ui.ChatFolds.ToolCallFold>
--- @field _pending_tool_call_ids string[]
--- @field _reopen_restore_tool_call_ids string[]
local ChatFolds = {}
ChatFolds.__index = ChatFolds

--- @param bufnr integer
--- @param tab_page_id integer
--- @return agentic.ui.ChatFolds
function ChatFolds:new(bufnr, tab_page_id)
    --- @type agentic.ui.ChatFolds
    local instance = setmetatable({
        _bufnr = bufnr,
        _tab_page_id = tab_page_id,
        _tool_call_folds = {},
        _pending_tool_call_ids = {},
        _reopen_restore_tool_call_ids = {},
    }, self)

    return instance
end

--- Reset all tracked fold state (e.g. on session cancel/clear)
function ChatFolds:reset()
    self._tool_call_folds = {}
    self._pending_tool_call_ids = {}
    self._reopen_restore_tool_call_ids = {}

    if vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = nil
    end
end

--- Resolve the folding policy for a given tool kind
--- @param kind string|nil
--- @return boolean enabled
--- @return integer min_lines
--- @return boolean closed_by_default
function ChatFolds._resolve_policy(kind)
    local folding = Config.folding
    if not folding or not folding.tool_calls then
        return false, 20, false
    end

    local tc = folding.tool_calls
    if not tc.enabled then
        return false, 20, false
    end

    --- @type integer
    local min_lines = tc.min_lines or 20
    --- @type boolean
    local closed_by_default = tc.closed_by_default or false

    if kind and tc.kinds and tc.kinds[kind] then
        local kind_config = tc.kinds[kind]
        if kind_config.min_lines ~= nil then
            --- @type integer
            min_lines = kind_config.min_lines
        end
        if kind_config.closed_by_default ~= nil then
            --- @type boolean
            closed_by_default = kind_config.closed_by_default
        end
    end

    return true, min_lines, closed_by_default
end

--- Resolve the body line range from the tool block extmark.
--- Returns 1-indexed start and end lines for the body (excluding header and footer).
--- @param bufnr integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param tool_call_id string
--- @return integer|nil body_start 1-indexed
--- @return integer|nil body_end 1-indexed
--- @return integer|nil block_start 0-indexed (for extmark)
function ChatFolds._resolve_body_range(bufnr, tool_call_blocks, tool_call_id)
    local tracker = tool_call_blocks[tool_call_id]
    if not tracker or not tracker.extmark_id then
        return nil, nil, nil
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        return nil, nil, nil
    end

    local start_row = pos[1] -- 0-indexed
    local details = pos[3]
    local end_row = details and details.end_row

    if not end_row then
        return nil, nil, nil
    end

    -- Body is between header (start_row) and footer (end_row), exclusive
    local body_start_1 = start_row + 2 -- 1-indexed, skip header
    local body_end_1 = end_row -- 1-indexed (end_row is 0-indexed footer, so end_row in 1-indexed is the last body line)

    if body_end_1 < body_start_1 then
        return nil, nil, nil
    end

    return body_start_1, body_end_1, start_row
end

--- Evaluate (or re-evaluate) fold eligibility for a tool call.
--- Preserves user toggle state across re-evaluations.
--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_ensure_tool_call_fold(tool_call_id, tool_call_blocks)
    local existing = self._tool_call_folds[tool_call_id]

    local tracker = tool_call_blocks[tool_call_id]
    local kind = tracker and tracker.kind

    local enabled, min_lines, closed_by_default =
        ChatFolds._resolve_policy(kind)

    local body_start, body_end = ChatFolds._resolve_body_range(
        self._bufnr,
        tool_call_blocks,
        tool_call_id
    )

    local body_lines = 0
    if body_start and body_end then
        body_lines = body_end - body_start + 1
    end

    local should_render = enabled and body_lines >= min_lines
    local status = tracker and tracker.status

    -- Don't fold in-progress tool calls
    if status == "pending" or status == "in_progress" then
        should_render = false
    end

    if existing then
        -- Re-evaluate but keep user toggle state
        existing.should_render_fold = should_render
        return existing
    end

    --- @type agentic.ui.ChatFolds.ToolCallFold
    local fold = {
        tool_call_id = tool_call_id,
        should_render_fold = should_render,
        default_closed = closed_by_default,
        fold_text_prefix = tracker and tracker.fold_text_prefix
            or ExtmarkBlock.BODY_PREFIX,
    }

    self._tool_call_folds[tool_call_id] = fold
    return fold
end

--- Get windows showing this buffer that belong to the owning tabpage
--- @return integer[] winids
function ChatFolds:_get_visible_windows()
    local wins = vim.fn.win_findbuf(self._bufnr)
    if #wins == 0 then
        return {}
    end

    --- @type integer[]
    local result = {}
    for _, winid in ipairs(wins) do
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, winid)
        if ok and tabpage == self._tab_page_id then
            table.insert(result, winid)
        end
    end

    return result
end

--- Configure fold-related window options
--- @param winid integer
function ChatFolds._configure_window(winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext = "v:lua.require'agentic.ui.chat_folds'.foldtext()"
end

--- Get whether a fold is closed at the given line in the given window
--- @param winid integer
--- @param line integer 1-indexed
--- @return boolean|nil is_closed true = closed, false = open, nil = no fold
function ChatFolds._get_fold_state(winid, line)
    if not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    --- @type boolean|nil
    local state = nil

    vim.api.nvim_win_call(winid, function()
        local fold_closed = vim.fn.foldclosed(line)
        if fold_closed == -1 then
            -- Check if there's actually a fold here (just open)
            local fold_level = vim.fn.foldlevel(line)
            if fold_level > 0 then
                state = false -- fold exists but is open
            end
            -- else: no fold at this line, state stays nil
        else
            state = true -- fold is closed
        end
    end)

    return state
end

--- Set fold state at a given line in a window
--- @param winid integer
--- @param line integer 1-indexed
--- @param closed boolean
function ChatFolds._set_fold_state(winid, line, closed)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    vim.api.nvim_win_call(winid, function()
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        if closed then
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zC")
        else
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zO")
        end
    end)
end

--- Store fold text prefix for use by the foldtext function
--- @param tool_call_id string
--- @param prefix string
function ChatFolds:_set_fold_text_prefix(tool_call_id, prefix)
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local prefixes = vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] or {}
    prefixes[tool_call_id] = prefix
    vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = prefixes
end

--- Clear fold text prefix for a tool call
--- @param tool_call_id string
function ChatFolds:_clear_fold_text_prefix(tool_call_id)
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local prefixes = vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] or {}
    prefixes[tool_call_id] = nil
    vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = prefixes
end

--- Decide the default state for a fold
--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
--- @return boolean closed
function ChatFolds._decide_default_state(tool_call_fold)
    if tool_call_fold.last_known_fold_state ~= nil then
        return tool_call_fold.last_known_fold_state
    end

    return tool_call_fold.default_closed or false
end

--- Sync a single tool call fold to all visible windows.
--- This creates or recreates the fold, preserving user toggle state.
--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:sync_tool_call(tool_call_id, tool_call_blocks)
    local fold = self:_ensure_tool_call_fold(tool_call_id, tool_call_blocks)

    if not fold.should_render_fold then
        return
    end

    local winids = self:_get_visible_windows()

    if #winids == 0 then
        -- Widget is hidden; queue for later
        if fold.last_known_fold_state ~= nil then
            table.insert(self._reopen_restore_tool_call_ids, tool_call_id)
        else
            table.insert(self._pending_tool_call_ids, tool_call_id)
        end
        return
    end

    local body_start, body_end = ChatFolds._resolve_body_range(
        self._bufnr,
        tool_call_blocks,
        tool_call_id
    )

    if not body_start or not body_end then
        return
    end

    self:_set_fold_text_prefix(
        tool_call_id,
        fold.fold_text_prefix or ExtmarkBlock.BODY_PREFIX
    )

    local desired_state = ChatFolds._decide_default_state(fold)

    for _, winid in ipairs(winids) do
        self:_sync_fold_to_window(winid, body_start, body_end, desired_state)
    end
end

--- Create/recreate a fold in a specific window, preserving view
--- @param winid integer
--- @param body_start integer 1-indexed
--- @param body_end integer 1-indexed
--- @param closed boolean
function ChatFolds:_sync_fold_to_window(winid, body_start, body_end, closed)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    ChatFolds._configure_window(winid)

    vim.api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()

        -- Delete any existing fold at this range
        vim.api.nvim_win_set_cursor(0, { body_start, 0 })
        --- @diagnostic disable-next-line: param-type-mismatch
        pcall(vim.cmd, "silent! normal! zD")

        -- Create the new fold
        --- @diagnostic disable-next-line: param-type-mismatch
        pcall(vim.cmd, string.format("silent! %d,%dfold", body_start, body_end))

        -- Set desired state
        if closed then
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zC")
        else
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zO")
        end

        vim.fn.winrestview(view)
    end)
end

--- Capture fold states from all visible windows before hiding.
--- Stores the current open/closed state so it can be restored on reshow.
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:capture_visible_fold_states(tool_call_blocks)
    local winids = self:_get_visible_windows()
    if #winids == 0 then
        return
    end

    -- Use first visible window as representative
    local winid = winids[1]

    for tool_call_id, fold in pairs(self._tool_call_folds) do
        if fold.should_render_fold then
            local body_start = ChatFolds._resolve_body_range(
                self._bufnr,
                tool_call_blocks,
                tool_call_id
            )

            if body_start then
                local state = ChatFolds._get_fold_state(winid, body_start)
                if state ~= nil then
                    fold.last_known_fold_state = state
                end
            end
        end
    end
end

--- Capture fold state for a single tool call before buffer update
--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:capture_tool_call_fold_state(tool_call_id, tool_call_blocks)
    local fold = self._tool_call_folds[tool_call_id]
    if not fold or not fold.should_render_fold then
        return
    end

    local winids = self:_get_visible_windows()
    if #winids == 0 then
        return
    end

    local body_start = ChatFolds._resolve_body_range(
        self._bufnr,
        tool_call_blocks,
        tool_call_id
    )

    if body_start then
        local state = ChatFolds._get_fold_state(winids[1], body_start)
        if state ~= nil then
            fold.last_known_fold_state = state
        end
    end
end

--- Called on BufWinEnter to configure the window and process pending folds
--- @param winid integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:on_buf_win_enter(winid, tool_call_blocks)
    local folding = Config.folding
    if
        not folding
        or not folding.tool_calls
        or not folding.tool_calls.enabled
    then
        return
    end

    ChatFolds._configure_window(winid)

    -- Process reopen-restore queue (known fold states)
    local restore_ids = self._reopen_restore_tool_call_ids
    self._reopen_restore_tool_call_ids = {}

    for _, tool_call_id in ipairs(restore_ids) do
        local fold = self._tool_call_folds[tool_call_id]
        if fold and fold.should_render_fold then
            local body_start, body_end = ChatFolds._resolve_body_range(
                self._bufnr,
                tool_call_blocks,
                tool_call_id
            )

            if body_start and body_end then
                local desired = ChatFolds._decide_default_state(fold)
                self:_sync_fold_to_window(winid, body_start, body_end, desired)
            end
        end
    end

    -- Process pending queue (new folds, no prior state)
    local pending_ids = self._pending_tool_call_ids
    self._pending_tool_call_ids = {}

    for _, tool_call_id in ipairs(pending_ids) do
        local fold = self._tool_call_folds[tool_call_id]
        if fold and fold.should_render_fold then
            local body_start, body_end = ChatFolds._resolve_body_range(
                self._bufnr,
                tool_call_blocks,
                tool_call_id
            )

            if body_start and body_end then
                local desired = ChatFolds._decide_default_state(fold)
                self:_sync_fold_to_window(winid, body_start, body_end, desired)
            end
        end
    end
end

--- Truncate a string to fit within a target display width.
--- Respects multi-byte characters and double-width glyphs.
--- @param str string
--- @param target_width integer
--- @return string truncated
function ChatFolds._truncate_str(str, target_width)
    if target_width <= 0 then
        return ""
    end

    local str_width = vim.fn.strdisplaywidth(str)
    if str_width <= target_width then
        return str
    end

    local cur_width = 0
    local byte_idx = 0
    local char_count = vim.fn.strchars(str)

    for i = 0, char_count - 1 do
        local ch = vim.fn.strcharpart(str, i, 1)
        local ch_width = vim.fn.strdisplaywidth(ch)
        if cur_width + ch_width > target_width then
            break
        end
        cur_width = cur_width + ch_width
        byte_idx = byte_idx + #ch
    end

    return string.sub(str, 1, byte_idx)
end

--- Get the available text width for the current window.
--- Accounts for number column, sign column, fold column, etc.
--- @return integer width
function ChatFolds._get_text_width()
    local winid = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(winid)
    if info and info[1] then
        return info[1].width - info[1].textoff
    end
    return vim.api.nvim_win_get_width(winid)
end

--- Build virtual text chunks for a fold line, preserving original highlighting.
--- Queries extmark decorations and content highlights on the first fold line.
--- @param bufnr integer
--- @param foldstart integer 1-indexed
--- @return string[][] chunks
function ChatFolds._build_fold_virt_text(bufnr, foldstart)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        foldstart - 1,
        foldstart,
        false
    )[1] or ""

    --- @type string[][]
    local chunks = {}

    -- Get decoration prefix (inline virtual text from NS_DECORATIONS)
    local dec_marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_DECORATIONS,
        { foldstart - 1, 0 },
        { foldstart - 1, 0 },
        { details = true }
    )

    if #dec_marks > 0 and dec_marks[1][4] then
        local vt = dec_marks[1][4].virt_text
        if vt then
            for _, chunk in ipairs(vt) do
                table.insert(chunks, chunk)
            end
        end
    else
        table.insert(
            chunks,
            { ExtmarkBlock.BODY_PREFIX, "AgenticCodeBlockFence" }
        )
    end

    -- Get content highlight from NS_DIFF_HIGHLIGHTS
    local hl_marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_DIFF_HIGHLIGHTS,
        { foldstart - 1, 0 },
        { foldstart - 1, -1 },
        { details = true }
    )

    if #hl_marks > 0 and hl_marks[1][4] and hl_marks[1][4].hl_group then
        table.insert(chunks, { line, hl_marks[1][4].hl_group })
    else
        table.insert(chunks, { line, "Comment" })
    end

    return chunks
end

--- Static foldtext function called by Neovim.
--- Returns virtual text chunks preserving the original line highlighting.
--- @return string[][]
function ChatFolds.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local foldstart = vim.v.foldstart
    local foldend = vim.v.foldend
    local line_count = foldend - foldstart + 1

    local folding = Config.folding
    if folding.foldtext then
        local chunks = ChatFolds._build_fold_virt_text(bufnr, foldstart)
        local width = ChatFolds._get_text_width()

        local ok, result = pcall(folding.foldtext, {
            virt_text = chunks,
            line_count = line_count,
            width = width,
            truncate = ChatFolds._truncate_str,
        })
        if ok and result then
            return result
        end
    end

    -- Default: prefix + line count (matches original foldtext style)
    local prefixes = vim.b[bufnr][FOLD_TEXT_PREFIXES_VAR]
    local prefix = ExtmarkBlock.BODY_PREFIX

    if prefixes then
        for _, p in pairs(prefixes) do
            if type(p) == "string" then
                prefix = p
                break
            end
        end
    end

    return {
        {
            string.format("%s [%d lines folded]", prefix, line_count),
            "Comment",
        },
    }
end

return ChatFolds
