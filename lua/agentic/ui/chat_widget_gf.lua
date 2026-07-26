local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- Implements `gf` ("go to file under cursor") support for widget buffers.
--- Widget windows have `winfixbuf` set (see widget_layout.lua), so builtin
--- `gf` fails with E1513. This resolves the path manually and opens it in
--- the user's main editor window instead of the widget window.
--- @class agentic.ui.ChatWidgetGf
local M = {}

--- A candidate path-like token found on a widget line, with its 1-indexed
--- inclusive byte column range (of the RAW, untrimmed match) and an
--- optional trailing `:LINE[:COL]`.
--- @class agentic.ui.ChatWidgetGf.PathCandidate
--- @field text string trailing-punctuation-trimmed text, tried first
--- @field raw_text string untrimmed text, tried if `text` doesn't resolve
--- @field start_col integer
--- @field end_col integer
--- @field target_line? integer
--- @field target_col? integer

--- Characters considered part of a path token, mirroring Neovim's default
--- `'isfname'` (`@,48-57,/,.,-,_,+,,,#,$,%,~,=`) so we recognize roughly the
--- same tokens builtin `gf` would. `\128-\255` additionally admits UTF-8
--- lead/continuation bytes (Lua's `%w` is byte-based and ASCII-only), so
--- non-ASCII path components (`café/foo.lua`, `文档/foo.lua`) aren't
--- silently truncated at the first multi-byte character. All matching here
--- is byte-oriented (`string.find`/`string.sub`), and `cursor_col` is
--- likewise a byte column (from `nvim_win_get_cursor`), so multi-byte
--- tokens don't desync the column math.
local PATH_CHAR_CLASS = "[%w/%.%-_+,#$%%~=\128-\255]"

--- Sentence/list punctuation that commonly trails a path mention
--- ("`...at src/foo.lua.`", "`src/foo.lua, and...`"). Unlike Vim's own
--- `<cfile>`, our character class above treats these as valid path
--- characters, so they must be trimmed explicitly before treating the
--- token as a path. Only `.` and `,` are listed: the other characters a
--- caller might expect here (`;`, `:`, `)`, `]`, `}`, `'`, `"`) are not
--- members of `PATH_CHAR_CLASS`, so the tokenizer's scan already stops
--- before it ever reaches them -- they can never appear in a raw match.
local TRAILING_PUNCTUATION_PATTERN = "[%.,]+$"

--- @param digits string
--- @return integer
local function to_integer(digits)
    return math.floor(tonumber(digits) --[[@as number]])
end

--- @param text string
--- @return string trimmed
local function strip_trailing_punctuation(text)
    return (text:gsub(TRAILING_PUNCTUATION_PATTERN, ""))
end

--- @param abs_path string|nil
--- @return boolean
local function is_readable_file(abs_path)
    return abs_path ~= nil
        and abs_path ~= ""
        and vim.fn.filereadable(abs_path) == 1
        and vim.fn.isdirectory(abs_path) == 0
end

--- @param line_text string
--- @param end_col integer 1-indexed, inclusive end of the (raw) token
--- @return integer|nil target_line
--- @return integer|nil target_col
local function parse_suffix(line_text, end_col)
    local rest = line_text:sub(end_col + 1)

    local line_str, col_str = rest:match("^:(%d+):(%d+)")
    if line_str and col_str then
        return to_integer(line_str), to_integer(col_str)
    end

    line_str = rest:match("^:(%d+)")
    if line_str then
        return to_integer(line_str), nil
    end

    return nil, nil
end

--- Finds every path-like token on the line. A token qualifies as a
--- candidate if EITHER:
--- - it contains both a path separator/dot AND an alphanumeric character
---   (so `src/foo-bar.lua` or `foo.lua` qualify, but a lone `-` bullet or a
---   `-`/`.` separator doesn't), OR
--- - the cursor is actually on it -- so an extensionless name the user is
---   pointing at (`Makefile`, `Dockerfile`, `LICENSE`) is still considered,
---   the same way builtin `gf` would.
--- Trailing sentence punctuation (see `TRAILING_PUNCTUATION_PATTERN`) is
--- trimmed from `text` (kept verbatim in `raw_text`) so prose like
--- "`see foo.lua.`" or "`foo.lua, then`" resolves correctly.
--- @param line_text string
--- @param cursor_col integer 1-indexed byte column
--- @return agentic.ui.ChatWidgetGf.PathCandidate[]
function M.find_path_candidates(line_text, cursor_col)
    --- @type agentic.ui.ChatWidgetGf.PathCandidate[]
    local candidates = {}
    local search_from = 1

    while true do
        local start_col, end_col =
            line_text:find(PATH_CHAR_CLASS .. "+", search_from)
        if not start_col then
            break
        end
        --- @cast end_col integer

        local raw_text = line_text:sub(start_col, end_col)
        search_from = end_col + 1

        local trimmed_text = strip_trailing_punctuation(raw_text)
        local contains_cursor = cursor_col >= start_col
            and cursor_col <= end_col
        local looks_path_like = trimmed_text ~= ""
            and trimmed_text:find("[/%.]")
            and trimmed_text:find("%w")

        if trimmed_text ~= "" and (contains_cursor or looks_path_like) then
            local target_line, target_col = parse_suffix(line_text, end_col)
            --- @type agentic.ui.ChatWidgetGf.PathCandidate
            local candidate = {
                text = trimmed_text,
                raw_text = raw_text,
                start_col = start_col,
                end_col = end_col,
                target_line = target_line,
                target_col = target_col,
            }
            table.insert(candidates, candidate)
        end
    end

    return candidates
end

--- @param candidate agentic.ui.ChatWidgetGf.PathCandidate
--- @param cursor_col integer 1-indexed byte column
--- @return integer
local function distance_from_cursor(candidate, cursor_col)
    if cursor_col < candidate.start_col then
        return candidate.start_col - cursor_col
    elseif cursor_col > candidate.end_col then
        return cursor_col - candidate.end_col
    end
    return 0
end

--- Orders candidate indices by distance from the cursor (nearest first).
--- Ties keep left-to-right (original) order for determinism, since
--- `table.sort` is not guaranteed stable.
--- @param candidates agentic.ui.ChatWidgetGf.PathCandidate[]
--- @param cursor_col integer 1-indexed byte column
--- @return integer[] indices
local function order_indices_by_distance(candidates, cursor_col)
    --- @type integer[]
    local indices = {}
    for index = 1, #candidates do
        indices[index] = index
    end

    table.sort(indices, function(a, b)
        local candidate_a, candidate_b = candidates[a], candidates[b]
        if not candidate_a or not candidate_b then
            return a < b
        end

        local distance_a = distance_from_cursor(candidate_a, cursor_col)
        local distance_b = distance_from_cursor(candidate_b, cursor_col)
        if distance_a == distance_b then
            return a < b
        end
        return distance_a < distance_b
    end)

    return indices
end

--- Resolves `path_text` to an absolute path, expanding `~`/env vars and
--- resolving relative paths against Neovim's current working directory
--- (there is no separate per-session cwd/root concept in this codebase --
--- `FileSystem.to_smart_path`, used to render paths in the transcript,
--- resolves against the same cwd).
--- @param path_text string|nil
--- @return string|nil abs_path
function M.resolve_absolute_path(path_text)
    if not path_text or path_text == "" then
        return nil
    end

    local expanded = vim.fn.expand(path_text)
    if not expanded or expanded == "" then
        return nil
    end

    return FileSystem.to_absolute_path(expanded)
end

--- Tries to resolve a single candidate: the trimmed text first, then (if
--- different) the untrimmed raw text, so a file genuinely named with a
--- trailing punctuation character still works.
--- @param candidate agentic.ui.ChatWidgetGf.PathCandidate
--- @return string|nil abs_path
local function resolve_candidate(candidate)
    local abs_path = M.resolve_absolute_path(candidate.text)
    if is_readable_file(abs_path) then
        return abs_path
    end

    if candidate.raw_text ~= candidate.text then
        abs_path = M.resolve_absolute_path(candidate.raw_text)
        if is_readable_file(abs_path) then
            return abs_path
        end
    end

    return nil
end

--- Picks the `gf` target for the given line/cursor: tries every path
--- candidate on the line ordered by distance from the cursor (nearest
--- first) -- so duplicate mentions of the same path resolve to the one the
--- cursor is actually on, and a real file elsewhere on the line still wins
--- over an unresolvable one that merely happens to be closer (e.g. widget
--- renderers that prefix paths with bullets/icons leave the cursor on
--- decoration rather than on the path itself).
--- @param line_text string
--- @param cursor_col integer 1-indexed byte column
--- @return string|nil abs_path
--- @return integer|nil target_line
--- @return integer|nil target_col
--- @return string|nil attempted_text best-effort text to report in a warning
function M.resolve_gf_target(line_text, cursor_col)
    local candidates = M.find_path_candidates(line_text, cursor_col)
    if #candidates == 0 then
        return nil, nil, nil, nil
    end

    local order = order_indices_by_distance(candidates, cursor_col)

    for _, index in ipairs(order) do
        local candidate = candidates[index]
        if candidate then
            local abs_path = resolve_candidate(candidate)
            if abs_path then
                return abs_path,
                    candidate.target_line,
                    candidate.target_col,
                    candidate.text
            end
        end
    end

    local nearest_index = order[1]
    local nearest_candidate = nearest_index and candidates[nearest_index] or nil
    local attempted_text = nearest_candidate and nearest_candidate.text or nil
    return nil, nil, nil, attempted_text
end

--- @param ChatWidget agentic.ui.ChatWidget
function M.attach(ChatWidget)
    --- Resolves the file under the cursor and opens it in the user's main
    --- editor window -- specifically the split the user was last focused in
    --- (`_get_preferred_editor_focus_winid`), not just any non-widget
    --- window. If the widget is currently maximized, minimizes it first
    --- (maximized state has closed every editor window, so there is nothing
    --- to open the file into otherwise; `_restore_maximize_state` refocuses
    --- the previously-focused editor leaf synchronously, so the preferred
    --- window is resolved AFTER that call, not before).
    function ChatWidget:_goto_file_under_cursor()
        local current_winid = vim.api.nvim_get_current_win()
        local line_text = vim.api.nvim_get_current_line()
        local cursor_col = vim.api.nvim_win_get_cursor(current_winid)[2] + 1

        local abs_path, target_line, target_col, attempted_text =
            M.resolve_gf_target(line_text, cursor_col)

        if not abs_path then
            Logger.notify(
                "Cannot resolve file under cursor"
                    .. (attempted_text and (": " .. attempted_text) or ""),
                vim.log.levels.WARN,
                { title = "Agentic: go to file" }
            )
            return
        end

        -- Load the buffer BEFORE touching maximize state: a minimize cannot
        -- be undone (re-maximizing captures the just-restored layout as the
        -- new baseline), so nothing here may disturb the layout unless the
        -- rest of the navigation can still succeed.
        local target_bufnr = vim.fn.bufadd(abs_path)
        vim.fn.bufload(target_bufnr)
        if not vim.api.nvim_buf_is_valid(target_bufnr) then
            Logger.notify(
                "Failed to load file: " .. abs_path,
                vim.log.levels.WARN,
                { title = "Agentic: go to file" }
            )
            return
        end

        if self._maximize_state ~= nil then
            self:_clear_maximize_state("gf", {
                restore_layout = true,
                keep_widget = true,
            })
        end

        -- Resolved after any maximize restore above so it reflects the
        -- freshly refocused editor leaf; when not maximized, the current
        -- window is still the widget window `gf` was pressed in, so this
        -- falls through to `winnr('#')` -- the split the user came from.
        -- `open_buf_in_editor_window` independently re-validates this
        -- winid (see `_classify_editor_window`) before ever touching it.
        local preferred_winid = self:_get_preferred_editor_focus_winid()

        local target_winid =
            self:open_buf_in_editor_window(target_bufnr, preferred_winid)
        if not target_winid or not vim.api.nvim_win_is_valid(target_winid) then
            Logger.notify(
                "Failed to open a window for: " .. abs_path,
                vim.log.levels.WARN,
                { title = "Agentic: go to file" }
            )
            return
        end

        vim.api.nvim_set_current_win(target_winid)

        if target_line then
            local line_count = vim.api.nvim_buf_line_count(target_bufnr)
            local clamped_line = math.max(1, math.min(target_line, line_count))
            local col = target_col and math.max(0, target_col - 1) or 0
            pcall(
                vim.api.nvim_win_set_cursor,
                target_winid,
                { clamped_line, col }
            )
        end
    end
end

return M
