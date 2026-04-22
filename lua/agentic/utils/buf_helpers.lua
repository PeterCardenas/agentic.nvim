local Logger = require("agentic.utils.logger")

--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- @class agentic.utils.BufHelpers.KeymapOpts
--- @field buffer? integer
--- @field desc? string
--- @field nowait? boolean
--- @field silent? boolean
--- @field noremap? boolean
--- @field expr? boolean
--- @field remap? boolean

--- Executes a callback with the buffer set to modifiable.
--- Returns false when the buffer is invalid or the callback errors.
--- Otherwise returns the callback's own return value.
--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|false result
function BufHelpers.with_modifiable(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local original_modifiable =
        vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    local ok, response = pcall(callback, bufnr)

    vim.api.nvim_set_option_value(
        "modifiable",
        original_modifiable,
        { buf = bufnr }
    )

    if not ok then
        Logger.notify(
            "Error in with_modifiable: \n" .. tostring(response),
            vim.log.levels.ERROR,
            { title = "🐞 Error with modifiable callback" }
        )
        return false
    end

    return response
end

function BufHelpers.start_insert_on_last_char()
    vim.cmd("normal! G$")
    vim.cmd("startinsert!")
end

--- @param winid integer
--- @return integer|nil line_count
--- @return integer|nil last_row
--- @return integer|nil last_col
local function get_window_bottom_position(winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return nil, nil, nil
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, nil, nil
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count <= 0 then
        return nil, nil, nil
    end

    local last_row = math.floor(line_count - 1)
    local last_line = vim.api.nvim_buf_get_lines(
        bufnr,
        last_row,
        line_count,
        false
    )[1] or ""
    local last_col = math.floor(#last_line)

    return line_count, last_row, last_col
end

--- @param winid integer
--- @param start_row integer
--- @param start_vcol integer|nil
--- @param max_height integer|nil
--- @return integer
local function get_window_tail_height(winid, start_row, start_vcol, max_height)
    if start_vcol and start_vcol > 0 then
        if max_height and max_height > 0 then
            return vim.api.nvim_win_text_height(winid, {
                start_row = start_row,
                start_vcol = start_vcol,
                max_height = max_height,
            }).all
        end

        return vim.api.nvim_win_text_height(winid, {
            start_row = start_row,
            start_vcol = start_vcol,
        }).all
    end

    if max_height and max_height > 0 then
        return vim.api.nvim_win_text_height(winid, {
            start_row = start_row,
            max_height = max_height,
        }).all
    end

    return vim.api.nvim_win_text_height(winid, {
        start_row = start_row,
    }).all
end

--- @param winid integer
--- @return boolean
function BufHelpers.is_window_bottom_visible(winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return false
    end

    local view = vim.api.nvim_win_call(winid, function()
        return vim.fn.winsaveview()
    end)
    local start_row = math.max(0, math.floor(view.topline - 1))
    local start_vcol = math.floor(view.skipcol or 0)
    local win_height = vim.api.nvim_win_get_height(winid)
    local tail_height =
        get_window_tail_height(winid, start_row, start_vcol, win_height + 1)

    return tail_height <= win_height
end

--- Scroll a window to the buffer bottom.
--- Uses a view-based alignment so wrapped lines, virtual footer lines, and
--- smoothscroll all agree on the same visible bottom.
--- @param winid integer
function BufHelpers.scroll_window_to_bottom(winid)
    local line_count, last_row, last_col = get_window_bottom_position(winid)
    if not line_count or not last_row or not last_col then
        return
    end

    local win_height = vim.api.nvim_win_get_height(winid)
    local topline = line_count
    local skipcol = 0
    local tail_height = get_window_tail_height(winid, last_row, nil, nil)

    if tail_height >= win_height then
        local overflow = math.max(0, tail_height - win_height)

        if overflow > 0 then
            skipcol = vim.api.nvim_win_text_height(winid, {
                start_row = last_row,
                max_height = overflow,
            }).end_vcol
        end
    else
        local start_row = last_row

        while start_row > 0 do
            local height = get_window_tail_height(
                winid,
                start_row - 1,
                nil,
                win_height + 1
            )

            if height > win_height then
                break
            end

            start_row = start_row - 1
        end

        topline = start_row + 1
    end

    vim.api.nvim_win_call(winid, function()
        vim.fn.winrestview({
            lnum = line_count,
            col = last_col,
            curswant = vim.v.maxcol,
            topline = topline,
            skipcol = skipcol,
        })
    end)
end

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|nil
function BufHelpers.execute_on_buffer(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    return vim.api.nvim_buf_call(bufnr, function()
        return callback(bufnr)
    end)
end

--- Sets a keymap for a specific buffer.
--- @param bufnr integer
--- @param mode string|string[]
--- @param lhs string
--- @param rhs string|fun():any
--- @param opts agentic.utils.BufHelpers.KeymapOpts|nil
function BufHelpers.keymap_set(bufnr, mode, lhs, rhs, opts)
    --- @type agentic.utils.BufHelpers.KeymapOpts
    local resolved = opts or {}
    resolved.buffer = bufnr
    vim.keymap.set(mode, lhs, rhs, resolved)
end

--- Sets multiple keymaps from a KeymapValue config entry for a specific buffer.
--- Normalizes the config value (string, string[], or array of string/KeymapEntry)
--- and calls keymap_set for each binding.
--- @param keymaps agentic.UserConfig.KeymapValue
--- @param bufnr integer
--- @param callback fun():any
--- @param opts agentic.utils.BufHelpers.KeymapOpts|nil
function BufHelpers.multi_keymap_set(keymaps, bufnr, callback, opts)
    if type(keymaps) == "string" then
        keymaps = { keymaps }
    end

    for _, key in ipairs(keymaps) do
        --- @type string|string[]
        local modes = "n"
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        --- @diagnostic disable-next-line: param-type-mismatch
        BufHelpers.keymap_set(bufnr, modes, keymap, callback, opts)
    end
end

--- @param bufnr integer
--- @return boolean
function BufHelpers.is_buffer_empty(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if #lines == 0 then
        return true
    end

    -- Check if buffer contains only whitespace or a single empty line
    if #lines == 1 and lines[1]:match("^%s*$") then
        return true
    end

    -- Check if all lines are whitespace
    for _, line in ipairs(lines) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

function BufHelpers.feed_ESC_key()
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "nx",
        false
    )
end

return BufHelpers
