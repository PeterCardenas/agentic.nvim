--- @alias agentic.UserConfig.ProviderName
--- | "claude-acp"
--- | "claude-agent-acp"
--- | "gemini-acp"
--- | "codex-acp"
--- | "opencode-acp"
--- | "cursor-acp"
--- | "auggie-acp"
--- | "mistral-vibe-acp"

--- @alias agentic.UserConfig.HeaderRenderFn fun(parts: agentic.ui.ChatWidget.HeaderParts): string|nil

--- User config headers - each panel can have either config parts or a custom render function
--- @alias agentic.UserConfig.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts|agentic.UserConfig.HeaderRenderFn|nil>

--- Data passed to the on_prompt_submit hook
--- @class agentic.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- Data passed to the on_response_complete hook
--- @class agentic.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed
---
--- Data passed to the on_session_update hook
--- @class agentic.UserConfig.SessionUpdateData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field update agentic.acp.SessionUpdateMessage ACP session update details.

--- Data passed to the on_file_edit hook
--- @class agentic.UserConfig.FileEditData
--- @field file_path string The absolute path to the edited file
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- @class agentic.UserConfig.Hooks
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil
--- @field on_session_update? fun(data: agentic.UserConfig.SessionUpdateData): nil
--- @field on_file_edit? fun(data: agentic.UserConfig.FileEditData): nil

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>
--- @field diff_preview table<string, string>
--- @field chat_navigation table<string, string>

--- Window options passed to nvim_set_option_value
--- Overrides default options (wrap, linebreak, winfixbuf, winfixheight)
--- @alias agentic.UserConfig.WinOpts table<string, boolean|number|string>

--- @class agentic.UserConfig.ChatIcons
--- @field user string
--- @field agent string

--- Nested partial types for user config overrides
--- @class (partial) agentic.PartialUserConfig.Windows.Chat: agentic.UserConfig.Windows.Chat
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Windows.Input: agentic.UserConfig.Windows.Input
--- @field height? number
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Windows.Code: agentic.UserConfig.Windows.Code
--- @field max_height? number
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Windows.Files: agentic.UserConfig.Windows.Files
--- @field max_height? number
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Windows.Diagnostics: agentic.UserConfig.Windows.Diagnostics
--- @field max_height? number
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Windows.Todos: agentic.UserConfig.Windows.Todos
--- @field display? boolean
--- @field max_height? number
--- @field win_opts? agentic.UserConfig.WinOpts
--- @class (partial) agentic.PartialUserConfig.Keymaps: agentic.UserConfig.Keymaps
--- @field widget? table<string, agentic.UserConfig.KeymapValue>
--- @field prompt? table<string, agentic.UserConfig.KeymapValue>
--- @field diff_preview? table<string, string>
--- @field chat_navigation? table<string, string>
--- @class (partial) agentic.PartialUserConfig.SpinnerChars: agentic.UserConfig.SpinnerChars
--- @class (partial) agentic.PartialUserConfig.StatusIcons: agentic.UserConfig.StatusIcons
--- @field pending? string
--- @field completed? string
--- @field failed? string
--- @class (partial) agentic.PartialUserConfig.DiagnosticIcons: agentic.UserConfig.DiagnosticIcons
--- @class (partial) agentic.PartialUserConfig.PermissionIcons: agentic.UserConfig.PermissionIcons
--- @class (partial) agentic.PartialUserConfig.ChatIcons: agentic.UserConfig.ChatIcons
--- @field user? string
--- @field agent? string
--- @class (partial) agentic.PartialUserConfig.MessageIcons: agentic.UserConfig.MessageIcons
--- @class (partial) agentic.PartialUserConfig.FilePicker: agentic.UserConfig.FilePicker
--- @class (partial) agentic.PartialUserConfig.ImagePaste: agentic.UserConfig.ImagePaste
--- @class (partial) agentic.PartialUserConfig.AutoScroll: agentic.UserConfig.AutoScroll
--- @class (partial) agentic.PartialUserConfig.DiffPreview: agentic.UserConfig.DiffPreview
--- @field enabled? boolean
--- @field layout? "inline" | "split"
--- @field center_on_navigate_hunks? boolean
--- @class (partial) agentic.PartialUserConfig.Settings: agentic.UserConfig.Settings
--- @field move_cursor_to_chat_on_submit? boolean

--- Windows partial with nested type overrides
--- @class (partial) agentic.PartialUserConfig.Windows: agentic.UserConfig.Windows
--- @field position? agentic.UserConfig.Windows.Position
--- @field width? string|number
--- @field height? string|number
--- @field stack_width_ratio? number
--- @field chat? agentic.PartialUserConfig.Windows.Chat
--- @field input? agentic.PartialUserConfig.Windows.Input
--- @field code? agentic.PartialUserConfig.Windows.Code
--- @field files? agentic.PartialUserConfig.Windows.Files
--- @field diagnostics? agentic.PartialUserConfig.Windows.Diagnostics
--- @field todos? agentic.PartialUserConfig.Windows.Todos

--- Top-level partial config -- all UserConfig fields become optional
--- Nested fields override to use partial variants
--- @class (partial) agentic.PartialUserConfig: agentic.UserConfig
--- @field debug? boolean
--- @field provider? agentic.UserConfig.ProviderName
--- @field acp_providers? table<string, agentic.acp.ACPProviderConfig>
--- @field hooks? agentic.UserConfig.Hooks
--- @field headers? agentic.UserConfig.Headers
--- @field folding? agentic.UserConfig.Folding
--- @field session_restore? agentic.UserConfig.SessionRestore
--- @field windows? agentic.PartialUserConfig.Windows
--- @field keymaps? agentic.PartialUserConfig.Keymaps
--- @field spinner_chars? agentic.PartialUserConfig.SpinnerChars
--- @field status_icons? agentic.PartialUserConfig.StatusIcons
--- @field diagnostic_icons? agentic.PartialUserConfig.DiagnosticIcons
--- @field permission_icons? agentic.PartialUserConfig.PermissionIcons
--- @field chat_icons? agentic.PartialUserConfig.ChatIcons
--- @field message_icons? agentic.PartialUserConfig.MessageIcons
--- @field file_picker? agentic.PartialUserConfig.FilePicker
--- @field image_paste? agentic.PartialUserConfig.ImagePaste
--- @field auto_scroll? agentic.PartialUserConfig.AutoScroll
--- @field diff_preview? agentic.PartialUserConfig.DiffPreview
--- @field settings? agentic.PartialUserConfig.Settings

--- @class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    --- @type agentic.UserConfig.ProviderName
    provider = "claude-agent-acp",

    --- @type table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
    acp_providers = {
        ["claude-agent-acp"] = {
            name = "Claude Agent ACP",
            command = "claude-agent-acp",
            env = {},
        },

        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            env = {},
        },

        ["gemini-acp"] = {
            name = "Gemini ACP",
            command = "gemini",
            args = { "--experimental-acp" },
            env = {},
        },

        ["codex-acp"] = {
            name = "Codex ACP",
            -- https://github.com/zed-industries/codex-acp/releases
            -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
            command = "codex-acp",
            args = {
                -- "-c",
                -- "features.web_search_request=true", -- disabled as it doesn't send proper tool call messages
            },
            env = {},
        },

        ["opencode-acp"] = {
            name = "OpenCode ACP",
            command = "opencode",
            args = { "acp" },
            env = {},
        },

        ["cursor-acp"] = {
            name = "Cursor Agent ACP",
            command = "agent",
            args = { "acp" },
            env = {},
            auth_method = "cursor_login",
        },

        ["auggie-acp"] = {
            name = "Auggie ACP",
            command = "auggie",
            args = {
                "--acp",
            },
            env = {},
        },

        ["mistral-vibe-acp"] = {
            name = "Mistral Vibe ACP",
            command = "vibe-acp",
            args = {},
            env = {},
        },
    },

    --- @class agentic.UserConfig.Windows.Chat
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Input
    --- @field height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Code
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Files
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Diagnostics
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Todos
    --- @field display boolean
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @alias agentic.UserConfig.Windows.Position "right"|"left"|"bottom"

    --- @class agentic.UserConfig.Windows
    --- @field position agentic.UserConfig.Windows.Position
    --- @field width string|number
    --- @field height string|number
    --- @field stack_width_ratio number
    --- @field chat agentic.UserConfig.Windows.Chat
    --- @field input agentic.UserConfig.Windows.Input
    --- @field code agentic.UserConfig.Windows.Code
    --- @field files agentic.UserConfig.Windows.Files
    --- @field diagnostics agentic.UserConfig.Windows.Diagnostics
    --- @field todos agentic.UserConfig.Windows.Todos
    windows = {
        position = "right",
        width = "40%",
        height = "30%",
        stack_width_ratio = 0.4,
        chat = { win_opts = {} },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = 10, win_opts = {} },
    },

    --- @type agentic.UserConfig.Keymaps
    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            close = "q",
            switch_provider = "<localLeader>s",
            switch_model = "<localLeader>m",
            switch_config_option = "<localLeader>o",
            cycle_windows = {
                {
                    "<Tab>",
                    mode = { "i", "n" },
                },
            },
            cycle_windows_reverse = {
                {
                    "<S-Tab>",
                    mode = { "i", "n" },
                },
            },
            toggle_prompt_code = "<leader>af", -- Global keymap to toggle between prompt and code window
            switch_model_global = "<leader>am", -- Global keymap to switch model
            switch_config_option_global = "<leader>ao", -- Global keymap to switch config options
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            submit = {
                "<CR>",
                {
                    "<C-s>",
                    mode = { "i", "n", "v" },
                },
            },

            paste_image = {
                {
                    "<localLeader>p",
                    mode = { "n" },
                },
                {
                    "<C-v>", -- Same as Claude-code in insert mode
                    mode = { "i" },
                },
            },

            accept_completion = {
                {
                    "<Tab>",
                    mode = { "i" },
                },
            },
        },

        --- Keys bindings for diff preview navigation
        diff_preview = {
            next_hunk = "]c",
            prev_hunk = "[c",
        },

        --- Keys bindings for chat navigation
        chat_navigation = {
            next_prompt = "]p",
            prev_prompt = "[p",
            last_agent_chunk = "]a",
            prev_agent_chunk = "[a",
        },
    },

    -- stylua: ignore start
    --- @class agentic.UserConfig.SpinnerChars
    --- @field generating string[]
    --- @field thinking string[]
    --- @field searching string[]
    --- @field busy string[]
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
        busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
    },
    -- stylua: ignore end

    --- Icons used to identify tool call states
    --- @class agentic.UserConfig.StatusIcons
    status_icons = {
        pending = "󰔛",
        completed = "✔",
        failed = "",
    },

    --- Icons used for diagnostics in the context panel
    --- @class agentic.UserConfig.DiagnosticIcons
    --- @field error string
    --- @field warn string
    --- @field info string
    --- @field hint string
    diagnostic_icons = {
        error = "❌",
        warn = "⚠️",
        info = "ℹ️",
        hint = "✨",
    },

    --- Icons used in agent messages (finish, error, etc.)
    --- @class agentic.UserConfig.MessageIcons
    message_icons = {
        thinking = "🧠",
        finished = "🏁",
        stopped = "🛑",
        error = "❌",
    },

    --- @class agentic.UserConfig.PermissionIcons
    permission_icons = {
        allow_once = "",
        allow_always = "",
        reject_once = "",
        reject_always = "󰜺",
    },

    --- @class agentic.UserConfig.FilePicker
    file_picker = {
        enabled = true,
    },

    --- @class agentic.UserConfig.ImagePaste
    --- @field enabled boolean Enable image drag-and-drop to add images to referenced files
    image_paste = {
        enabled = true,
    },

    --- @class agentic.UserConfig.AutoScroll
    --- @field threshold integer Lines from bottom to trigger auto-scroll (default: 10)
    auto_scroll = {
        threshold = 10,
    },

    --- Show diff preview for edit tool calls in the buffer
    --- @class agentic.UserConfig.DiffPreview
    --- @field enabled boolean
    --- @field layout "inline" | "split"
    --- @field center_on_navigate_hunks boolean
    diff_preview = {
        enabled = true,
        layout = "split",
        center_on_navigate_hunks = true,
    },

    --- @type agentic.UserConfig.Hooks
    hooks = {
        on_prompt_submit = nil,
        on_response_complete = nil,
        on_session_update = nil,
        on_file_edit = nil,
    },

    --- Customize window headers for each panel in the chat widget.
    --- Each header can be either:
    --- 1. A table with title and suffix fields
    --- 2. A function that receives header parts and returns a custom header string
    ---
    --- The context field is managed internally and shows dynamic info like counts.
    ---
    --- @type agentic.UserConfig.Headers
    headers = {},

    --- Per-kind folding overrides
    --- @class agentic.UserConfig.FoldingToolCallKindConfig
    --- @field closed_by_default? boolean
    --- @field min_lines? integer
    --- @field preview? boolean

    --- Tool call folding configuration
    --- @class agentic.UserConfig.FoldingToolCalls
    --- @field enabled boolean
    --- @field closed_by_default boolean
    --- @field min_lines integer
    --- @field preview boolean
    --- @field kinds? table<string, agentic.UserConfig.FoldingToolCallKindConfig>

    --- @class agentic.UserConfig.FoldtextInfo
    --- @field virt_text string[][] Highlighted virtual text chunks {{text, hl_group}, ...}
    --- @field line_count integer
    --- @field width integer Available text area width in columns
    --- @field truncate fun(str: string, target_width: integer): string

    --- @class agentic.UserConfig.Folding
    --- @field tool_calls agentic.UserConfig.FoldingToolCalls
    --- @field foldtext? fun(info: agentic.UserConfig.FoldtextInfo): string[][]

    --- Fold completed tool call output to keep chat compact
    --- @type agentic.UserConfig.Folding
    folding = {
        tool_calls = {
            enabled = true,
            closed_by_default = true,
            preview = true,
            min_lines = 20,
            kinds = {
                fetch = { min_lines = 8 },
                execute = { min_lines = 12 },
                read = { min_lines = 15 },
                edit = { closed_by_default = false },
            },
        },
        foldtext = nil,
    },

    --- Control various behaviors and features of the plugin
    --- @class agentic.UserConfig.Settings
    settings = {

        --- Automatically move cursor to chat window after submitting a prompt
        move_cursor_to_chat_on_submit = true,
    },

    --- @class agentic.UserConfig.SessionRestore
    --- @field storage_path? string Path to store session data; if nil, default path is used: ~/.cache/nvim/agentic/sessions/
    session_restore = {
        storage_path = nil,
    },
}

return ConfigDefault
