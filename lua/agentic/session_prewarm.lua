local SessionRegistry = require("agentic.session_registry")

local M = {}

local is_setup = false

---@type table<integer, string>
local prewarmed_cwd_by_tab = {}

---@param session agentic.SessionManager
---@return boolean
local function can_recreate_prewarmed_session(session)
    local message_count = session.chat_history
            and session.chat_history.messages
            and #session.chat_history.messages
        or 0

    return session._is_first_message == true
        and not session.is_generating
        and message_count > 0
        and message_count <= 1
        and session.file_list
        and session.file_list:is_empty()
        and session.code_selection
        and session.code_selection:is_empty()
        and session.diagnostics_list
        and session.diagnostics_list:is_empty()
        and session.todo_list
        and session.todo_list:is_empty()
end

---@param tab_page_id? integer
local function prewarm_session(tab_page_id)
    local resolved_tab_page_id = tab_page_id
        or vim.api.nvim_get_current_tabpage()
    if not vim.api.nvim_tabpage_is_valid(resolved_tab_page_id) then
        prewarmed_cwd_by_tab[resolved_tab_page_id] = nil
        return
    end

    local current_cwd = vim.fn.getcwd(-1, resolved_tab_page_id)
    --- @type agentic.SessionManager|nil
    local session = rawget(SessionRegistry.sessions, resolved_tab_page_id)
    local previous_cwd = prewarmed_cwd_by_tab[resolved_tab_page_id]

    if session ~= nil and previous_cwd ~= nil then
        local cwd_changed = current_cwd ~= "" and current_cwd ~= previous_cwd
        if cwd_changed then
            if can_recreate_prewarmed_session(session) then
                SessionRegistry.destroy_session(resolved_tab_page_id)
                session = nil
            else
                prewarmed_cwd_by_tab[resolved_tab_page_id] = current_cwd
                return
            end
        end
    end

    if not session then
        SessionRegistry.get_session_for_tab_page(resolved_tab_page_id)
    end

    if current_cwd ~= "" then
        prewarmed_cwd_by_tab[resolved_tab_page_id] = current_cwd
    end
end

---@param tab_page_id? integer
local function schedule_session_prewarm(tab_page_id)
    vim.schedule(function()
        pcall(prewarm_session, tab_page_id)
    end)
end

function M.setup()
    if is_setup then
        return
    end

    is_setup = true

    local prewarm_group =
        vim.api.nvim_create_augroup("AgenticSessionPrewarm", { clear = true })

    schedule_session_prewarm()

    vim.api.nvim_create_autocmd("TabEnter", {
        group = prewarm_group,
        callback = function()
            schedule_session_prewarm()
        end,
    })

    vim.api.nvim_create_autocmd("DirChanged", {
        group = prewarm_group,
        callback = function()
            schedule_session_prewarm()
        end,
    })

    vim.api.nvim_create_autocmd("TabClosed", {
        group = prewarm_group,
        callback = function()
            for tab_page_id, _ in pairs(prewarmed_cwd_by_tab) do
                if not vim.api.nvim_tabpage_is_valid(tab_page_id) then
                    prewarmed_cwd_by_tab[tab_page_id] = nil
                end
            end
        end,
    })
end

return M
