--- Pretty-print single-line JSON bodies in tool call output so they
--- read as multi-line blocks in the chat buffer and become easier to scan.
--- @class agentic.utils.JsonFormat
local M = {}

local INDENT = "  "
local MIN_LENGTH = 80

--- Decide whether a single-line string is worth pretty-printing. Cheap
--- structural check before paying for `vim.json.decode`.
--- @param line string
--- @return boolean is_json
local function looks_like_json(line)
    if #line < MIN_LENGTH then
        return false
    end

    local trimmed = line:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return false
    end

    local first = trimmed:sub(1, 1)
    local last = trimmed:sub(-1)

    if first == "{" and last == "}" then
        return true
    end

    if first == "[" and last == "]" then
        return true
    end

    return false
end

--- Distinguish array-shaped tables from object-shaped tables.
--- @param value table
--- @return boolean is_array
local function is_array(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end

    if count == 0 then
        return true
    end

    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end

    return true
end

--- @param value any
--- @param depth integer
--- @param parts string[]
local function encode(value, depth, parts)
    local value_type = type(value)

    if value_type == "nil" or value == vim.NIL then
        table.insert(parts, "null")
        return
    end

    if value_type == "boolean" then
        table.insert(parts, value and "true" or "false")
        return
    end

    if value_type == "number" then
        table.insert(parts, tostring(value))
        return
    end

    if value_type == "string" then
        table.insert(parts, vim.json.encode(value))
        return
    end

    if value_type ~= "table" then
        table.insert(parts, vim.json.encode(value))
        return
    end

    local indent = string.rep(INDENT, depth)
    local inner_indent = string.rep(INDENT, depth + 1)

    if is_array(value) then
        if #value == 0 then
            table.insert(parts, "[]")
            return
        end

        table.insert(parts, "[\n")
        for i, item in ipairs(value) do
            table.insert(parts, inner_indent)
            encode(item, depth + 1, parts)
            if i < #value then
                table.insert(parts, ",")
            end
            table.insert(parts, "\n")
        end
        table.insert(parts, indent)
        table.insert(parts, "]")
        return
    end

    --- @type (string|number)[]
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    if #keys == 0 then
        table.insert(parts, "{}")
        return
    end

    table.insert(parts, "{\n")
    for i, key in ipairs(keys) do
        table.insert(parts, inner_indent)
        table.insert(parts, vim.json.encode(tostring(key)))
        table.insert(parts, ": ")
        encode(value[key], depth + 1, parts)
        if i < #keys then
            table.insert(parts, ",")
        end
        table.insert(parts, "\n")
    end
    table.insert(parts, indent)
    table.insert(parts, "}")
end

--- Pretty-print a Lua value back to JSON with 2-space indentation.
--- @param value any
--- @return string formatted
local function pretty(value)
    --- @type string[]
    local parts = {}
    encode(value, 0, parts)
    return table.concat(parts)
end

--- Try to format a single string as pretty-printed JSON.
--- @param line string
--- @return string formatted
function M.format_line(line)
    if not looks_like_json(line) then
        return line
    end

    local ok, decoded = pcall(
        vim.json.decode,
        line,
        { luanil = { object = true, array = true } }
    )
    if not ok or type(decoded) ~= "table" then
        return line
    end

    return pretty(decoded)
end

--- Format a body only when it is a single line that parses as JSON.
--- @param lines string[]
--- @return string[] formatted
function M.format_lines(lines)
    if type(lines) ~= "table" then
        return lines
    end

    local has_trailing_blank = #lines == 2 and lines[2] == ""
    if #lines ~= 1 and not has_trailing_blank then
        return lines
    end

    local first_line = lines[1]
    if not first_line then
        return lines
    end

    local formatted = M.format_line(first_line)
    if formatted == first_line then
        return lines
    end

    local result = vim.split(formatted, "\n", { plain = true })
    if has_trailing_blank then
        table.insert(result, "")
    end

    return result
end

return M
