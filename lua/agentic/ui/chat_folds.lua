--- @diagnostic disable: unnecessary-if, param-type-mismatch, return-type-mismatch
local Config = require("agentic.config")
local ExtmarkBlock = require("agentic.utils.extmark_block")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")

local FOLD_TEXT_PREFIXES_VAR = "_agentic_fold_text_prefixes"
local MAX_FOLD_CLEAR_PASSES = 64

--- @class agentic.ui.ChatFolds.ToolCallFold
--- @field tool_call_id string
--- @field should_render_fold? boolean
--- @field default_closed? boolean
--- @field preview? boolean
--- @field min_lines? integer
--- @field last_known_fold_state? boolean true = closed, false = open (outer fold)
--- @field last_known_inner_fold_state? boolean true = closed, false = open (inner fold)
--- @field fold_text_prefix? string

--- @class agentic.ui.ChatFolds
--- @field _bufnr integer
--- @field _tab_page_id integer
--- @field _tool_call_folds table<string, agentic.ui.ChatFolds.ToolCallFold>
--- @field _sync_defer_depth? integer
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
        _sync_defer_depth = 0,
    }, self)

    return instance
end

function ChatFolds:reset()
    self._tool_call_folds = {}
    self._sync_defer_depth = 0

    if vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = nil
    end
end

--- @return boolean
function ChatFolds:_folding_enabled()
    local _ = self
    local folding = Config.folding
    return folding ~= nil
        and folding.tool_calls ~= nil
        and folding.tool_calls.enabled
end

--- @param kind string|nil
--- @return boolean enabled
--- @return integer min_lines
--- @return boolean closed_by_default
--- @return boolean preview
function ChatFolds._resolve_policy(kind)
    local folding = Config.folding
    if not folding or not folding.tool_calls then
        return false, 20, false, true
    end

    local tc = folding.tool_calls
    if not tc.enabled then
        return false, 20, false, true
    end

    --- @type integer
    local min_lines = tc.min_lines or 20
    --- @type boolean
    local closed_by_default = tc.closed_by_default or false
    --- @type boolean
    local preview = tc.preview ~= false

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
        if kind_config.preview ~= nil then
            --- @type boolean
            preview = kind_config.preview
        end
    end

    return true, min_lines, closed_by_default, preview
end

--- @param bufnr integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param tool_call_id string
--- @return integer|nil body_start 1-indexed
--- @return integer|nil body_end 1-indexed
--- @return integer|nil block_start 1-indexed
--- @return integer|nil block_end 1-indexed
function ChatFolds._resolve_ranges(bufnr, tool_call_blocks, tool_call_id)
    local tracker = tool_call_blocks[tool_call_id]
    if not tracker or not tracker.extmark_id then
        return nil, nil, nil, nil
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        return nil, nil, nil, nil
    end

    local start_row = pos[1]
    local end_row = pos[3] and pos[3].end_row

    if not end_row then
        return nil, nil, nil, nil
    end

    local body_start = start_row + 2
    local body_end = end_row

    if body_end < body_start then
        return nil, nil, nil, nil
    end

    return body_start, body_end, start_row + 1, end_row + 1
end

--- @param bufnr integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param tool_call_id string
--- @return integer|nil body_start
--- @return integer|nil body_end
--- @return integer|nil block_start
function ChatFolds._resolve_body_range(bufnr, tool_call_blocks, tool_call_id)
    local body_start, body_end, block_start =
        ChatFolds._resolve_ranges(bufnr, tool_call_blocks, tool_call_id)
    if not body_start or not block_start then
        return nil, nil, nil
    end

    return body_start, body_end, block_start - 1
end

--- @param bufnr integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param tool_call_id string
--- @return integer|nil block_start
--- @return integer|nil block_end
function ChatFolds._resolve_block_range(bufnr, tool_call_blocks, tool_call_id)
    local _, _, block_start, block_end =
        ChatFolds._resolve_ranges(bufnr, tool_call_blocks, tool_call_id)
    return block_start, block_end
end

--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_ensure_tool_call_fold(tool_call_id, tool_call_blocks)
    local existing = self._tool_call_folds[tool_call_id]

    local tracker = tool_call_blocks[tool_call_id]
    local kind = tracker and tracker.kind

    local enabled, min_lines, closed_by_default, preview =
        ChatFolds._resolve_policy(kind)

    local body_start, body_end =
        ChatFolds._resolve_ranges(self._bufnr, tool_call_blocks, tool_call_id)

    local body_lines = 0
    if body_start and body_end then
        body_lines = body_end - body_start + 1
    end

    local should_render = enabled and body_lines >= min_lines
    local status = tracker and tracker.status

    if status == "pending" or status == "in_progress" then
        should_render = false
    end

    if existing then
        existing.should_render_fold = should_render
        return existing
    end

    --- @type agentic.ui.ChatFolds.ToolCallFold
    local fold = {
        tool_call_id = tool_call_id,
        should_render_fold = should_render,
        default_closed = closed_by_default,
        preview = preview,
        min_lines = min_lines,
        fold_text_prefix = tracker and tracker.fold_text_prefix
            or ExtmarkBlock.BODY_PREFIX,
    }

    self._tool_call_folds[tool_call_id] = fold
    return fold
end

--- @return integer[]
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

--- @param winid integer
function ChatFolds._configure_window(winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext = "v:lua.require'agentic.ui.chat_folds'.foldtext()"
end

--- @param winid integer
--- @param line integer 1-indexed
--- @return boolean|nil is_closed
function ChatFolds._get_fold_state(winid, line)
    if not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    --- @type boolean|nil
    local state = nil

    vim.api.nvim_win_call(winid, function()
        local fold_closed = vim.fn.foldclosed(line)
        if fold_closed == -1 then
            if vim.fn.foldlevel(line) > 0 then
                state = false
            end
        else
            state = true
        end
    end)

    return state
end

--- @param body_start integer 1-indexed
--- @param body_end integer 1-indexed
function ChatFolds._delete_folds_in_current_window_range(body_start, body_end)
    local pass = 0

    while pass < MAX_FOLD_CLEAR_PASSES do
        local removed = false
        local line = body_end

        while line >= body_start do
            if vim.fn.foldlevel(line) > 0 then
                vim.api.nvim_win_set_cursor(0, { line, 0 })
                --- @diagnostic disable-next-line: param-type-mismatch
                pcall(vim.cmd, "silent! normal! zD")
                removed = true
                break
            end
            line = line - 1
        end

        if not removed then
            break
        end

        pass = pass + 1
    end
end

--- @param winid integer
--- @param range_start integer 1-indexed
--- @param range_end integer 1-indexed
function ChatFolds._delete_folds_in_window_range(winid, range_start, range_end)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    vim.api.nvim_win_call(winid, function()
        ChatFolds._delete_folds_in_current_window_range(range_start, range_end)
    end)
end

--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:delete_folds_for_tool_call(tool_call_id, tool_call_blocks)
    local block_start, block_end = ChatFolds._resolve_block_range(
        self._bufnr,
        tool_call_blocks,
        tool_call_id
    )

    if not block_start or not block_end then
        return
    end

    for _, winid in ipairs(self:_get_visible_windows()) do
        ChatFolds._delete_folds_in_window_range(winid, block_start, block_end)
    end
end

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
            pcall(vim.cmd, "silent! normal! zc")
        else
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zo")
        end
    end)
end

--- @param tool_call_id string
--- @param prefix string|nil
function ChatFolds:_set_fold_text_prefix(tool_call_id, prefix)
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local prefixes = vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] or {}
    prefixes[tool_call_id] = prefix
    vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = prefixes
end

--- @param tool_call_id string
function ChatFolds:_clear_fold_text_prefix(tool_call_id)
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local prefixes = vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] or {}
    prefixes[tool_call_id] = nil
    vim.b[self._bufnr][FOLD_TEXT_PREFIXES_VAR] = prefixes
end

--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
--- @return boolean outer_closed
--- @return boolean inner_closed
function ChatFolds._decide_default_states(tool_call_fold)
    local outer_closed = tool_call_fold.default_closed or false
    if tool_call_fold.last_known_fold_state ~= nil then
        outer_closed = tool_call_fold.last_known_fold_state --[[@as boolean]]
    end

    local inner_closed = tool_call_fold.preview ~= false
    if tool_call_fold.last_known_inner_fold_state ~= nil then
        inner_closed = tool_call_fold.last_known_inner_fold_state --[[@as boolean]]
    end

    return outer_closed, inner_closed
end

--- @param winid integer
--- @param body_start integer 1-indexed
--- @param body_end integer 1-indexed
--- @param block_start integer 1-indexed
--- @param block_end integer 1-indexed
--- @param fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_apply_fold_in_window(
    winid,
    body_start,
    body_end,
    block_start,
    block_end,
    fold
)
    local _ = self
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    ChatFolds._configure_window(winid)
    ChatFolds._delete_folds_in_window_range(winid, block_start, block_end)

    local outer_closed, inner_closed = ChatFolds._decide_default_states(fold)

    --- @type integer|nil
    local inner_start = nil
    if
        fold.preview
        and fold.min_lines
        and body_start + fold.min_lines <= body_end
    then
        inner_start = body_start + fold.min_lines
    end

    vim.api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()
        vim.api.nvim_win_set_cursor(0, { body_start, 0 })

        --- @diagnostic disable-next-line: param-type-mismatch
        pcall(vim.cmd, string.format("silent! %d,%dfold", body_start, body_end))

        if inner_start and inner_start <= body_end then
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zo")
            pcall(
                --- @diagnostic disable-next-line: param-type-mismatch
                vim.cmd,
                string.format("silent! %d,%dfold", inner_start, body_end)
            )

            if not inner_closed then
                vim.api.nvim_win_set_cursor(0, { inner_start, 0 })
                --- @diagnostic disable-next-line: param-type-mismatch
                pcall(vim.cmd, "silent! normal! zo")
            end

            if outer_closed then
                vim.api.nvim_win_set_cursor(0, { body_start, 0 })
                --- @diagnostic disable-next-line: param-type-mismatch
                pcall(vim.cmd, "silent! normal! zc")
            end
        elseif not outer_closed then
            --- @diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "silent! normal! zo")
        end

        vim.fn.winrestview(view)
    end)
end

--- Batch session replay: skip per-tool-call fold work until flush_sync.
function ChatFolds:defer_sync()
    self._sync_defer_depth = (self._sync_defer_depth or 0) + 1
end

--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:flush_sync(tool_call_blocks)
    local depth = self._sync_defer_depth or 0
    if depth <= 0 then
        return
    end

    self._sync_defer_depth = depth - 1
    if self._sync_defer_depth > 0 then
        return
    end

    self:sync_all_tool_calls(tool_call_blocks)
end

--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return string[]
function ChatFolds._sorted_tool_call_ids(bufnr, tool_call_blocks)
    --- @type { id: string, start: integer }[]
    local entries = {}

    for tool_call_id in pairs(tool_call_blocks) do
        local body_start =
            ChatFolds._resolve_ranges(bufnr, tool_call_blocks, tool_call_id)
        table.insert(entries, {
            id = tool_call_id,
            start = body_start or math.huge,
        })
    end

    table.sort(entries, function(a, b)
        return a.start < b.start
    end)

    --- @type string[]
    local ids = {}
    for _, entry in ipairs(entries) do
        table.insert(ids, entry.id)
    end

    return ids
end

--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:_sync_tool_call_impl(tool_call_id, tool_call_blocks)
    local fold = self:_ensure_tool_call_fold(tool_call_id, tool_call_blocks)

    if not fold.should_render_fold then
        self:_clear_fold_text_prefix(tool_call_id)
        self:delete_folds_for_tool_call(tool_call_id, tool_call_blocks)
        return
    end

    local winids = self:_get_visible_windows()
    if #winids == 0 then
        return
    end

    for _, winid in ipairs(winids) do
        self:_sync_tool_call_to_window(winid, tool_call_id, tool_call_blocks)
    end
end

--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:sync_tool_call(tool_call_id, tool_call_blocks)
    if (self._sync_defer_depth or 0) > 0 then
        return
    end

    self:_sync_tool_call_impl(tool_call_id, tool_call_blocks)
end

--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:sync_all_tool_calls(tool_call_blocks)
    if not self:_folding_enabled() then
        return
    end

    for _, tool_call_id in
        ipairs(ChatFolds._sorted_tool_call_ids(self._bufnr, tool_call_blocks))
    do
        self:_sync_tool_call_impl(tool_call_id, tool_call_blocks)
    end
end

--- @param winid integer
--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_capture_fold_state_at_window(
    winid,
    tool_call_id,
    tool_call_blocks,
    fold
)
    local body_start, body_end =
        ChatFolds._resolve_ranges(self._bufnr, tool_call_blocks, tool_call_id)

    if not body_start then
        return
    end

    --- @diagnostic disable-next-line: param-type-mismatch
    local outer_state = ChatFolds._get_fold_state(winid, body_start)
    if outer_state ~= nil then
        fold.last_known_fold_state = outer_state
    end

    if
        outer_state == false
        and fold.preview
        and fold.min_lines
        and body_end
    then
        local inner_start = body_start + fold.min_lines
        if inner_start <= body_end then
            --- @diagnostic disable-next-line: param-type-mismatch
            local inner_state = ChatFolds._get_fold_state(winid, inner_start)
            if inner_state ~= nil then
                fold.last_known_inner_fold_state = inner_state
            end
        end
    end
end

--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:capture_visible_fold_states(tool_call_blocks)
    local winids = self:_get_visible_windows()
    if #winids == 0 then
        return
    end

    local winid = winids[1]
    for tool_call_id, fold in pairs(self._tool_call_folds) do
        if fold.should_render_fold then
            self:_capture_fold_state_at_window(
                winid,
                tool_call_id,
                tool_call_blocks,
                fold
            )
        end
    end
end

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

    self:_capture_fold_state_at_window(
        winids[1],
        tool_call_id,
        tool_call_blocks,
        fold
    )
end

--- @param winid integer
--- @param tool_call_id string
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:_sync_tool_call_to_window(
    winid,
    tool_call_id,
    tool_call_blocks
)
    local fold = self:_ensure_tool_call_fold(tool_call_id, tool_call_blocks)

    if not fold.should_render_fold then
        return
    end

    local body_start, body_end, block_start, block_end =
        ChatFolds._resolve_ranges(self._bufnr, tool_call_blocks, tool_call_id)

    if not body_start or not body_end or not block_start or not block_end then
        return
    end

    self:_set_fold_text_prefix(
        tool_call_id,
        fold.fold_text_prefix or ExtmarkBlock.BODY_PREFIX
    )

    self:_apply_fold_in_window(
        winid,
        body_start,
        body_end,
        block_start,
        block_end,
        fold
    )
end

--- @param winid integer
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
function ChatFolds:on_buf_win_enter(winid, tool_call_blocks)
    if not self:_folding_enabled() then
        return
    end

    for _, tool_call_id in
        ipairs(ChatFolds._sorted_tool_call_ids(self._bufnr, tool_call_blocks))
    do
        self:_sync_tool_call_to_window(winid, tool_call_id, tool_call_blocks)
    end
end

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

--- @return integer width
function ChatFolds._get_text_width()
    local winid = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(winid)
    if info and info[1] then
        return info[1].width - info[1].textoff
    end
    return vim.api.nvim_win_get_width(winid)
end

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

--- @return string[][]
function ChatFolds.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local foldstart = vim.v.foldstart
    local foldend = vim.v.foldend
    local line_count = math.floor(foldend - foldstart + 1)

    local folding = Config.folding
    if folding and folding.foldtext then
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
