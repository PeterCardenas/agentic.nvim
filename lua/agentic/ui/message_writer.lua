--- @diagnostic disable: unnecessary-if, param-type-mismatch, return-type-mismatch
local ToolCallDiff = require("agentic.ui.tool_call_diff")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffPreview = require("agentic.ui.diff_preview")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_THOUGHT_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_thought_highlights")

local THOUGHT_LABEL_PREFIX = "Thinking: "
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_PERMISSION_BUTTONS =
    vim.api.nvim_create_namespace("agentic_permission_buttons")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")
local NS_PROMPT_POSITIONS =
    vim.api.nvim_create_namespace("agentic_prompt_positions")
local NS_AGENT_MESSAGE_CHUNK_POSITIONS =
    vim.api.nvim_create_namespace("agentic_agent_message_chunk_positions")

--- Decode base64 image data to a temp file and return a markdown image link.
--- @param data string
--- @param mime_type string
--- @return string|nil markdown
local function base64_image_to_markdown(data, mime_type)
    if not FileSystem.MIME_TO_EXT[mime_type] then
        return nil
    end

    local path, err = FileSystem.decode_base64_to_temp_file(data, mime_type)
    if path then
        return "![image](" .. path .. ")"
    end
    Logger.debug("Failed to decode image: " .. (err or "unknown error"))
    return nil
end

--- Extract displayable text from an ACP content block.
--- For text content, returns the text directly.
--- For image content, decodes to a temp file and returns a markdown image link.
--- For resource content with an image blob, decodes and returns a markdown image link.
--- @param content agentic.acp.Content|nil
--- @return string|nil text
local function extract_content_text(content)
    if not content then
        return nil
    end

    if content.type == "text" then
        return content.text
    end

    if content.type == "image" and content.data and content.mimeType then
        return base64_image_to_markdown(content.data, content.mimeType)
    end

    if content.type == "resource" and content.resource then
        local res = content.resource
        if res.blob and res.mimeType then
            return base64_image_to_markdown(res.blob, res.mimeType)
        end
    end

    return nil
end

--- @param start_row integer 0-indexed
--- @param lines string[]
--- @return integer row 0-indexed
local function resolve_first_inserted_row(start_row, lines)
    local row = start_row
    local line_index = 1

    while line_index <= #lines and lines[line_index] == "" do
        row = row + 1
        line_index = line_index + 1
    end

    return row
end

--- @param bufnr integer
--- @return integer row 0-indexed
local function get_append_start_row(bufnr)
    if BufHelpers.is_buffer_empty(bufnr) then
        return 0
    end

    return vim.api.nvim_buf_line_count(bufnr)
end

--- @param session_update string|nil
--- @return boolean
local function is_agent_message_update(session_update)
    return session_update == "agent_message_chunk"
end

--- @param bufnr integer
--- @param start_row integer 0-indexed
--- @param lines string[]
local function record_agent_message_position(bufnr, start_row, lines)
    local message_row = resolve_first_inserted_row(start_row, lines)
    vim.api.nvim_buf_set_extmark(
        bufnr,
        NS_AGENT_MESSAGE_CHUNK_POSITIONS,
        message_row,
        0,
        {}
    )
end

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean

--- @class agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id string
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field kind? agentic.acp.ToolKind
--- @field argument? string

--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
--- @field kind agentic.acp.ToolKind
--- @field argument string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field fold_text_prefix? string Prefix for fold text display

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean
--- @field _scroll_scheduled? boolean
--- @field _on_content_changed? fun()
--- @field _thought_label_row? integer
--- @field _thought_label_start_col? integer
--- @field _thought_text_extmark_id? integer
--- @field _record_next_prompt? boolean
--- @field _pending_newline? boolean
--- @field _chat_folds? agentic.ui.ChatFolds
--- @field _cmdline_leave_scroll_pending? boolean
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- @return boolean
local function is_cmdline_active()
    local mode = vim.api.nvim_get_mode().mode
    if mode == "c" then
        return true
    end

    return vim.fn.win_gettype() == "command"
end

--- @param bufnr integer
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll = nil,
        _scroll_scheduled = false,
        _cmdline_leave_scroll_pending = false,
    }, self)

    return instance
end

--- @param callback fun()|nil
function MessageWriter:set_on_content_changed(callback)
    self._on_content_changed = callback
end

--- @param chat_folds agentic.ui.ChatFolds|nil
function MessageWriter:set_chat_folds(chat_folds)
    self._chat_folds = chat_folds
end

function MessageWriter:_notify_content_changed()
    if self._on_content_changed then
        self._on_content_changed()
    end
end

--- Wraps BufHelpers.with_modifiable and fires _notify_content_changed after.
--- The callback may return false to suppress the notification (e.g. on early-return without edits).
--- with_modifiable returns false for invalid buffers, which also suppresses notification.
--- @param fn fun(bufnr: integer): boolean|nil
function MessageWriter:_with_modifiable_and_notify_change(fn)
    local result = BufHelpers.with_modifiable(self.bufnr, fn)
    if result ~= false then
        self:_notify_content_changed()
    end
end

--- @private
function MessageWriter:_clear_thought_state()
    self._last_message_type = nil
    self._thought_label_row = nil
    self._thought_label_start_col = nil
    self._thought_text_extmark_id = nil
    self._pending_newline = nil
end

--- @private
--- @return boolean
function MessageWriter:_has_active_thought()
    return self._thought_label_row ~= nil
        and self._thought_label_start_col ~= nil
        and self._thought_text_extmark_id ~= nil
end

--- @param session_update string|nil
--- @return boolean
function MessageWriter:_should_record_agent_message_start(session_update)
    return is_agent_message_update(session_update)
        and not is_agent_message_update(self._last_message_type)
end

--- Writes a full message to the chat buffer and append two blank lines after
--- @param update agentic.acp.UserMessageChunk|agentic.acp.AgentMessageChunk
function MessageWriter:write_message(update)
    local text = extract_content_text(update.content)

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    local should_record_prompt = self._record_next_prompt
    local should_record_agent_message =
        self:_should_record_agent_message_start(update.sessionUpdate)
    self._record_next_prompt = nil

    self:_clear_thought_state()
    self._last_message_type = update.sessionUpdate
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local start_row = get_append_start_row(bufnr)

        self:_append_lines(lines)
        self:_append_lines({ "", "" })

        if should_record_prompt then
            -- Offset by 2 to point at the first content line
            -- (header line, blank line, content line)
            local content_row = math.min(
                start_row + 2,
                vim.api.nvim_buf_line_count(self.bufnr) - 1
            )
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                NS_PROMPT_POSITIONS,
                content_row,
                0,
                {}
            )
        end

        if should_record_agent_message then
            record_agent_message_position(bufnr, start_row, lines)
        end
    end)
end

--- Marks the next write_message() call as a user prompt, so the starting
--- line will be recorded for prompt navigation.
function MessageWriter:record_prompt_position()
    self._record_next_prompt = true
end

--- Returns 1-indexed line numbers of all recorded user prompts.
--- @return integer[] positions
function MessageWriter:get_prompt_positions()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return {}
    end

    local marks = vim.api.nvim_buf_get_extmarks(
        self.bufnr,
        NS_PROMPT_POSITIONS,
        0,
        -1,
        {}
    )
    --- @type integer[]
    local positions = {}
    for _, mark in ipairs(marks) do
        -- mark = { id, row (0-indexed), col }
        table.insert(positions, mark[2] + 1) -- convert to 1-indexed
    end
    return positions
end

--- Returns 1-indexed line numbers where agent messages start.
--- This records only the first `agent_message_chunk` after any non-message
--- update, whether that message arrived as streamed chunks or a full replayed
--- agent message.
--- @return integer[] positions
function MessageWriter:get_agent_message_chunk_positions()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return {}
    end

    local marks = vim.api.nvim_buf_get_extmarks(
        self.bufnr,
        NS_AGENT_MESSAGE_CHUNK_POSITIONS,
        0,
        -1,
        {}
    )
    --- @type integer[]
    local positions = {}
    local seen = {}
    for _, mark in ipairs(marks) do
        local line = mark[2] + 1
        if not seen[line] then
            seen[line] = true
            table.insert(positions, line)
        end
    end
    return positions
end

--- Clear prompt and agent chunk navigation extmarks.
function MessageWriter:clear_navigation_positions()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_PROMPT_POSITIONS,
        0,
        -1
    )
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_AGENT_MESSAGE_CHUNK_POSITIONS,
        0,
        -1
    )
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
function MessageWriter:write_message_chunk(update)
    local text = extract_content_text(update.content)

    if not text or text == "" then
        return
    end
    --- @cast text string

    -- Flush any deferred trailing newline from the previous chunk
    if self._pending_newline then
        text = "\n" .. text
        self._pending_newline = nil
    end

    local is_thought = update.sessionUpdate == "agent_thought_chunk"
    local was_thought = self._last_message_type == "agent_thought_chunk"
    local is_first_agent_message =
        self:_should_record_agent_message_start(update.sessionUpdate)
    local is_first_thought = is_thought
        and not was_thought
        and not self:_has_active_thought()

    if was_thought and not is_thought then
        -- Different message type, add newline before appending, to create visual separation
        -- only for thought -> message
        text = "\n\n" .. text
        self:_clear_thought_state()
    end

    if is_first_thought then
        text = "\n" .. THOUGHT_LABEL_PREFIX .. text
    end

    self._last_message_type = update.sessionUpdate

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        local lines_to_write = vim.split(text, "\n", { plain = true })

        -- Defer trailing empty line to prevent visual jerk.
        -- When a chunk ends with "\n", vim.split produces a trailing "".
        -- Writing that empty string creates a blank line that briefly flashes
        -- before the next chunk fills it. Instead, strip it and re-insert the
        -- newline at the start of the next chunk.
        if #lines_to_write > 1 and lines_to_write[#lines_to_write] == "" then
            table.remove(lines_to_write)
            self._pending_newline = true
        end

        local success, err = pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            last_line,
            start_col,
            last_line,
            start_col,
            lines_to_write
        )

        if not success then
            Logger.debug("Failed to set text in buffer", err, lines_to_write)
            return
        end

        if is_first_agent_message then
            record_agent_message_position(bufnr, last_line, lines_to_write)
        end

        if is_thought then
            if is_first_thought then
                -- The "\n" prefix puts "Thinking: " on the line after last_line
                local label_row = math.floor(last_line + 1)
                self._thought_label_row = label_row
                self._thought_label_start_col = 0
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_THOUGHT_HIGHLIGHTS,
                    label_row,
                    0,
                    {
                        end_row = label_row,
                        end_col = #THOUGHT_LABEL_PREFIX,
                        hl_group = Theme.HL_GROUPS.THOUGHT_LABEL,
                        priority = 110,
                    }
                )
            end

            if self._thought_label_row and self._thought_label_start_col then
                local new_last_line = vim.api.nvim_buf_line_count(bufnr) - 1
                local new_last_text = vim.api.nvim_buf_get_lines(
                    bufnr,
                    new_last_line,
                    new_last_line + 1,
                    false
                )[1] or ""
                self._thought_text_extmark_id = vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_THOUGHT_HIGHLIGHTS,
                    self._thought_label_row,
                    self._thought_label_start_col + #THOUGHT_LABEL_PREFIX,
                    {
                        id = self._thought_text_extmark_id,
                        end_row = new_last_line,
                        end_col = #new_last_text,
                        hl_group = Theme.HL_GROUPS.THOUGHT_TEXT,
                        priority = 100,
                    }
                )
            end
        end
    end)
end

--- @param lines string[]
--- @return nil
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.debug("Failed to append lines to buffer", err, lines)
    end
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_check_auto_scroll(bufnr)
    local _ = self
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end
    local winid = wins[1]
    local threshold = Config.auto_scroll and Config.auto_scroll.threshold

    if threshold == nil or threshold <= 0 then
        return false
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local distance_from_bottom = total_lines - cursor_line

    return distance_from_bottom <= threshold
end

--- Immediately scroll to bottom if auto-scroll is active.
--- Fold creation uses winsaveview/winrestview which can leave the view in a
--- wrong position when a fold collapses lines near the visible bottom.
--- Call this after fold operations to correct the view synchronously,
--- preventing a visual flash before the scheduled auto-scroll fires.
--- @private
function MessageWriter:_fix_scroll_after_fold()
    local should_scroll = self._should_auto_scroll
    if should_scroll == nil then
        should_scroll = self:_check_auto_scroll(self.bufnr)
    end

    if not should_scroll then
        return
    end

    if is_cmdline_active() then
        self:_defer_scroll_until_cmdline_leave(self.bufnr)
        return
    end

    local wins = vim.fn.win_findbuf(self.bufnr)
    if #wins > 0 then
        BufHelpers.scroll_window_to_bottom(wins[1])
    end
end

--- Force-enable auto-scroll for the current and subsequent writes.
--- Call this at turn boundaries (e.g. after writing the user prompt)
--- to guarantee new content is visible, regardless of prior scroll state.
function MessageWriter:enable_auto_scroll()
    self._should_auto_scroll = true
end

--- @param bufnr integer
function MessageWriter:_defer_scroll_until_cmdline_leave(bufnr)
    if self._cmdline_leave_scroll_pending then
        return
    end

    self._cmdline_leave_scroll_pending = true

    vim.api.nvim_create_autocmd("CmdlineLeave", {
        once = true,
        callback = function()
            self._cmdline_leave_scroll_pending = false

            if not vim.api.nvim_buf_is_valid(bufnr) then
                self._should_auto_scroll = nil
                return
            end

            self:_auto_scroll(bufnr)
        end,
    })
end

--- @param bufnr integer Buffer number to scroll
function MessageWriter:_auto_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = self:_check_auto_scroll(bufnr)
    end

    if is_cmdline_active() then
        if self._should_auto_scroll then
            self:_defer_scroll_until_cmdline_leave(bufnr)
        else
            self._should_auto_scroll = nil
        end
        return
    end

    if self._scroll_scheduled then
        return
    end
    self._scroll_scheduled = true

    vim.schedule(function()
        self._scroll_scheduled = false

        if vim.api.nvim_buf_is_valid(bufnr) then
            if self._should_auto_scroll then
                local wins = vim.fn.win_findbuf(bufnr)
                if #wins > 0 then
                    if not BufHelpers.is_window_bottom_visible(wins[1]) then
                        BufHelpers.scroll_window_to_bottom(wins[1])
                    end
                end
            end
        end

        self._should_auto_scroll = nil
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    self._last_message_type = nil
    self._pending_newline = nil
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local kind = tool_call_block.kind

        -- Always add a leading blank line for spacing the previous message chunk
        self:_append_lines({ "" })

        local lines, highlight_ranges =
            self:_prepare_block_lines(tool_call_block)

        self:_append_lines(lines)

        local end_row = math.floor(vim.api.nvim_buf_line_count(bufnr) - 1)
        -- Derive start_row from end_row after the append to handle the
        -- empty-buffer edge case where _append_lines replaces from line 0
        -- instead of appending.
        local start_row = math.floor(end_row - #lines + 1)
        local body_start = math.floor(start_row + 1)
        local body_end = math.floor(end_row - 1)

        self:_apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind,
            highlight_ranges
        )

        tool_call_block.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
                header_line = start_row,
                body_start = body_start,
                body_end = body_end,
                footer_line = end_row,
                hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
            })

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        -- Store fold text prefix for the fold display
        tool_call_block.fold_text_prefix = ExtmarkBlock.BODY_PREFIX

        self:_apply_header_highlight(start_row, tool_call_block.status)
        self:_apply_status_footer(end_row, tool_call_block.status)

        self:_append_lines({ "", "" })

        if self._chat_folds then
            self._chat_folds:sync_tool_call(
                tool_call_block.tool_call_id,
                self.tool_call_blocks
            )
        end
    end)

    self:_fix_scroll_after_fold()
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBase
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.debug(
            "Tool call block not found, ID: ",
            tool_call_block.tool_call_id
        )

        return
    end

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.debug(
            "Extmark not found",
            { tool_call_id = tracker.tool_call_id }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = tracker.tool_call_id, details = details }
        )
        return
    end

    -- Capture fold state before modifying buffer content
    if self._chat_folds then
        self._chat_folds:capture_tool_call_fold_state(
            tool_call_block.tool_call_id,
            self.tool_call_blocks
        )
    end

    -- Preserve fold text prefix across updates
    tracker.fold_text_prefix = tracker.fold_text_prefix
        or ExtmarkBlock.BODY_PREFIX

    self:_with_modifiable_and_notify_change(function(bufnr)
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content
        if already_has_diff then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return false
            end

            self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
            tracker.decoration_extmark_ids =
                self:_render_decorations(start_row, old_end_row)

            self:_clear_status_namespace(start_row, old_end_row)
            self:_apply_status_highlights_if_present(
                start_row,
                old_end_row,
                tracker.status
            )

            return false
        end

        self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
        self:_clear_status_namespace(start_row, old_end_row)

        -- Delete existing folds at the OLD body range before replacing lines.
        -- nvim_buf_set_lines shifts manual folds by the net line delta instead
        -- of deleting them; without this cleanup stale folds stack on each update.
        if self._chat_folds then
            self._chat_folds:delete_folds_for_tool_call(
                tool_call_block.tool_call_id,
                self.tool_call_blocks
            )
        end

        local new_lines, highlight_ranges = self:_prepare_block_lines(tracker)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                self:_apply_block_highlights(
                    bufnr,
                    start_row,
                    new_end_row,
                    tracker.kind,
                    highlight_ranges
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
        })

        tracker.decoration_extmark_ids =
            self:_render_decorations(start_row, new_end_row)

        self:_apply_status_highlights_if_present(
            start_row,
            new_end_row,
            tracker.status
        )

        -- Sync fold after content update
        if self._chat_folds then
            self._chat_folds:sync_tool_call(
                tool_call_block.tool_call_id,
                self.tool_call_blocks
            )
        end
    end)

    self:_fix_scroll_after_fold()
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local _ = self
    local kind = tool_call_block.kind
    local argument = tool_call_block.argument

    -- Sanitize argument to prevent newlines in the header line
    -- nvim_buf_set_lines doesn't accept array items with embedded newlines
    argument = argument:gsub("\n", "\\n")

    local lines = {
        string.format(" %s(%s) ", kind, argument),
    }

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            table.insert(lines, string.format("Read %d lines", line_count))

            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = {
                type = "comment",
                line_index = #lines - 1,
            }

            table.insert(highlight_ranges, range)
        end
    elseif tool_call_block.diff then
        local diff_blocks = ToolCallDiff.extract_diff_blocks({
            path = argument,
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        })

        local lang = Theme.get_language_from_path(argument)

        -- Hack to avoid triple backtick conflicts in markdown files
        table.insert(lines, "````" .. lang)

        for _, block in ipairs(diff_blocks) do
            local old_count = #block.old_lines
            local new_count = #block.new_lines
            local is_new_file = old_count == 0
            local is_modification = old_count == new_count and old_count > 0

            if is_new_file then
                for _, new_line in ipairs(block.new_lines) do
                    local line_index = #lines
                    table.insert(lines, new_line)

                    --- @type agentic.ui.MessageWriter.HighlightRange
                    local range = {
                        line_index = line_index,
                        type = "new",
                        old_line = nil,
                        new_line = new_line,
                    }

                    table.insert(highlight_ranges, range)
                end
            else
                local filtered = ToolCallDiff.filter_unchanged_lines(
                    block.old_lines,
                    block.new_lines
                )

                -- Insert old lines (removed content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        local line_index = #lines
                        table.insert(lines, pair.old_line)

                        --- @type agentic.ui.MessageWriter.HighlightRange
                        local range = {
                            line_index = line_index,
                            type = "old",
                            old_line = pair.old_line,
                            new_line = is_modification and pair.new_line or nil,
                        }

                        table.insert(highlight_ranges, range)
                    end
                end

                -- Insert new lines (added content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.new_line then
                        local line_index = #lines
                        table.insert(lines, pair.new_line)

                        if not is_modification then
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new",
                                old_line = nil,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        else
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new_modification",
                                old_line = pair.old_line,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        end
                    end
                end
            end
        end

        table.insert(lines, "````")
    else
        if tool_call_block.body then
            vim.list_extend(lines, tool_call_block.body)
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges
end

--- Display permission request buttons at the end of the buffer
--- @param options agentic.acp.PermissionOption[]
--- @return integer button_start_row Start row of button block
--- @return integer button_end_row End row of button block
--- @return table<integer, string> option_mapping Mapping from number (1-N) to option_id
function MessageWriter:display_permission_buttons(tool_call_id, options)
    local option_mapping = {}

    local lines_to_append = {
        "### Waiting for your response: ",
        "",
    }

    local tracker = self.tool_call_blocks[tool_call_id]

    if tracker then
        -- Sanitize argument to prevent newlines in the permission request, neovim throws error
        local sanitized_argument = tracker.argument:gsub("\n", "\\n")

        -- Get buffer width and limit the display line
        local winid = vim.fn.bufwinid(self.bufnr)

        local buf_width = 80 -- default fallback width, in case buf is not visible
        if winid ~= -1 then
            buf_width = vim.api.nvim_win_get_width(winid)
        end

        local tool_line =
            string.format(" %s(%s)", tracker.kind, sanitized_argument)

        -- Truncate if longer than buffer width, leaving space for "...)"
        if #tool_line > buf_width then
            tool_line = tool_line:sub(1, buf_width - 4) .. "...)"
        end

        vim.list_extend(lines_to_append, {
            tool_line,
            "", -- Blank line prevents markdown inline markers from spanning to next content
        })
    end

    for i, option in ipairs(options) do
        table.insert(
            lines_to_append,
            string.format(
                "%d. %s %s",
                i,
                Config.permission_icons[option.kind] or "",
                option.name
            )
        )
        option_mapping[i] = option.optionId
    end

    table.insert(lines_to_append, "--- ---")

    local hint_line_index =
        DiffPreview.add_navigation_hint(tracker, lines_to_append)

    table.insert(lines_to_append, "")

    -- Ensure exactly one empty separator line before the permission block.
    -- During reanchor, remove_permission_buttons leaves a trailing empty
    -- line — reuse it instead of adding another one.
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local last_line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        line_count - 1,
        line_count,
        false
    )[1]

    if last_line == "" then
        -- Buffer already ends with an empty line (left by
        -- remove_permission_buttons during reanchor). Reuse it as
        -- separator — include it in the block range so it gets
        -- cleaned up, but don't add another one.
        line_count = line_count - 1
    else
        -- No trailing empty line — prepend one as separator
        table.insert(lines_to_append, 1, "")
    end

    -- The separator line shifts hint position by 1 in both cases:
    -- existing empty line included in block range, or prepended empty line.
    if hint_line_index then
        hint_line_index = hint_line_index + 1
    end

    local button_start_row = line_count

    self:_auto_scroll(self.bufnr)

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines_to_append)
    end)

    local button_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    if hint_line_index then
        DiffPreview.apply_hint_styling(
            self.bufnr,
            NS_PERMISSION_BUTTONS,
            button_start_row,
            hint_line_index
        )
    end

    -- Create extmark to track button block
    vim.api.nvim_buf_set_extmark(
        self.bufnr,
        NS_PERMISSION_BUTTONS,
        button_start_row,
        0,
        {
            end_row = button_end_row,
            right_gravity = false,
        }
    )

    return button_start_row, button_end_row, option_mapping
end

--- @param start_row integer Start row of button block
--- @param end_row integer End row of button block
function MessageWriter:remove_permission_buttons(start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_PERMISSION_BUTTONS,
        start_row,
        end_row + 1
    )

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        pcall(
            vim.api.nvim_buf_set_lines,
            bufnr,
            start_row,
            end_row + 1,
            false,
            {
                "", -- a leading as separator from previous content
            }
        )
    end)
end

--- Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
--- @param bufnr integer
--- @param start_row integer Header line number
--- @param end_row integer Footer line number
--- @param kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(start_row, highlight_ranges)
    elseif kind ~= "edit" and kind ~= "switch_mode" then
        -- Apply Comment highlight for non-edit blocks without diffs
        for line_idx = start_row + 1, end_row - 1 do
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                line_idx,
                line_idx + 1,
                false
            )[1]
            if line and #line > 0 then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    line_idx,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
end

--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_diff_highlights(start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                self.bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
end

--- @param header_line integer 0-indexed header line number
--- @param status string|nil Status value (pending, completed, etc.)
function MessageWriter:_apply_header_highlight(header_line, status)
    if not status or status == "" then
        return
    end

    local line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        header_line,
        header_line + 1,
        false
    )[1]
    if not line then
        return
    end

    local hl_group = Theme.get_status_hl_group(status)
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, header_line, 0, {
        end_col = #line,
        hl_group = hl_group,
    })
end

--- @param footer_line integer 0-indexed footer line number
--- @param status string|nil Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(footer_line, status)
    if
        not vim.api.nvim_buf_is_valid(self.bufnr)
        or not status
        or status == ""
    then
        return
    end

    local icons = Config.status_icons or {}

    local icon = icons[status] or ""
    local hl_group = Theme.get_status_hl_group(status)

    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, footer_line, 0, {
        virt_text = {
            { string.format(" %s %s ", icon, status), hl_group },
        },
        virt_text_pos = "overlay",
    })
end

--- @param ids integer[]|nil
function MessageWriter:_clear_decoration_extmarks(ids)
    if not ids then
        return
    end

    for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS_DECORATIONS, id)
    end
end

--- @param start_row integer
--- @param end_row integer
--- @return integer[] decoration_extmark_ids
function MessageWriter:_render_decorations(start_row, end_row)
    return ExtmarkBlock.render_block(self.bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- @param start_row integer
--- @param end_row integer
function MessageWriter:_clear_status_namespace(start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_STATUS,
        start_row,
        end_row + 1
    )
end

--- @param start_row integer
--- @param end_row integer
--- @param status string|nil
function MessageWriter:_apply_status_highlights_if_present(
    start_row,
    end_row,
    status
)
    if status then
        self:_apply_header_highlight(start_row, status)
        self:_apply_status_footer(end_row, status)
    end
end

return MessageWriter
