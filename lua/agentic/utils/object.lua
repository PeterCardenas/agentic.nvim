--- @class agentic.utils.object
local M = {}

--- @param value table
--- @return boolean
local function has_array_entries(value)
    for key, _ in pairs(value) do
        if type(key) == "number" then
            return true
        end
    end

    return false
end

function M.deep_merge_into(target, ...)
    for _, source in ipairs({ ... }) do
        for k, v in pairs(source) do
            if
                type(v) == "table"
                and type(target[k]) == "table"
                and not has_array_entries(v)
                and not has_array_entries(target[k])
            then
                M.deep_merge_into(target[k], v)
            else
                target[k] = v
            end
        end
    end
    return target
end

--- @generic T: table
--- @param config T
--- @param user_config table|nil
--- @return T Config the static Config table with user's config merged into it
function M.merge_config(config, user_config)
    local default_keys = config and config.keymaps or {}
    local user_keys = user_config and user_config.keymaps or {}

    local merged = M.deep_merge_into(config, user_config)

    merged.keymaps = vim.tbl_deep_extend("force", default_keys, user_keys)

    return merged
end

return M
