# codex-complete.nvim

Codex-powered inline completions for Neovim, using your existing Codex CLI login
instead of an OpenAI API key.

The plugin waits briefly after you stop typing, sends bounded context from the
current buffer and relevant project definitions to a persistent `codex app-server` process, and offers the
result in your completion menu through [none-ls.nvim](https://github.com/nvimtools/none-ls.nvim)
(null-ls). Inline ghost text is available as an option. The buffer is not
changed until you accept the suggestion.

> [!IMPORTANT]
> `codex app-server` is currently marked experimental by the Codex CLI. The
> plugin validates the protocol at runtime and reports incompatibilities through
> `:checkhealth codex_complete`.

## Requirements

- Neovim 0.10 or newer
- [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)
- A ChatGPT account with Codex access
- A completed `codex login` browser or device-code flow
- [none-ls.nvim](https://github.com/nvimtools/none-ls.nvim) and an LSP
  completion client such as [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
  with `cmp-nvim-lsp`, to show suggestions in the completion menu

The Codex CLI supports ChatGPT sign-in for subscription access and caches that
login for local clients. See the official OpenAI documentation for
[Codex authentication](https://learn.chatgpt.com/docs/auth) and the
[app-server protocol](https://learn.chatgpt.com/docs/app-server).

## Installation

With `lazy.nvim`:

```lua
{
  "joegoggin/codex-complete.nvim",
  main = "codex_complete",
  dependencies = { "nvimtools/none-ls.nvim" },
  opts = {},
}
```

With `packer.nvim`:

```lua
use({
  "joegoggin/codex-complete.nvim",
  requires = { "nvimtools/none-ls.nvim" },
  config = function()
    require("codex_complete").setup()
  end,
})
```

Run the health check after installation:

```vim
:checkhealth codex_complete
```

## Completion menu (null-ls)

`setup()` registers a `codex_complete` completion source with null-ls when it
is installed. null-ls acts as a language server, so the suggestion appears in
any LSP completion client: nvim-cmp through `cmp-nvim-lsp`, blink.cmp, or
Neovim's built-in LSP completion. No extra source entry is needed.

The entry replaces the keyword being typed with the full suggestion, and its
documentation window previews multiline suggestions. The source does not start
requests itself; it answers once the automatic or manual request finishes, so
the entry appears a moment after the rest of the menu. Other null-ls
completion sources wait for it during that time.

Inline ghost text is off by default. Set `ghost_text = true` to draw the
suggestion at the cursor as well. The accept key works either way.

## Default controls

| Key | Mode | Action |
| --- | --- | --- |
| `Alt-;` (`<M-;>`) | Insert | Accept the current suggestion |
| `Alt-s` (`<M-s>`) | Insert | Request a suggestion manually |
| `<leader>ac` | Normal | Generate code from the comment under the cursor |
| `Alt-;` (`<M-;>`) | Normal | Accept a comment replacement |
| `<leader>at` | Normal | Toggle suggestions |
| `<leader>am` | Normal | Select the completion model |
| `<leader>ar` | Normal | Select the reasoning level |

Visible suggestions are dismissed when you continue typing or leave insert
mode. You can also dismiss them through `:CodexCompleteDismiss` or `dismiss()`.

Automatic suggestions are requested 200 milliseconds after typing stops. Every
new keystroke resets that timer and cancels an obsolete in-flight request. An
inline, theme-colored spinner appears while Codex is generating the suggestion.

With `ghost_text = true`, suggestion text uses black text on a dark green
(`#50A14F`) background applied only behind the ghost text, keeping it distinct
from comments. Comment replacement previews use the same highlights. Both
highlight groups are configurable, and the background can be disabled.

The last suggestion is cached in memory for each open buffer. Returning to the
same editing context restores it immediately without another request. Typing a
matching prefix keeps the untyped remainder visible; accepting or explicitly
dismissing the suggestion clears that buffer's cache. Fully typing the cached
suggestion does not request another completion until additional text stops
matching and the debounce period elapses.

After accepting a suggestion, automatic completion waits for the next
insert-mode edit before starting a new debounce period. Cursor movement alone
does not request another suggestion, while manual requests remain available.

Common auto-paired closing delimiters are treated as part of the cached
suggestion. While the cursor remains inside a generated `()`, `[]`, or `{}`
pair, the plugin shows the full remaining suggestion around the existing
closing delimiter without starting a request.

### Generate code from a comment

Place the cursor on a comment and press `<leader>ac`, or run
`:CodexCompleteComment`. The complete Tree-sitter comment node is used as an
instruction, so line comments and multiline block comments are supported. The
generated replacement is shown as highlighted virtual lines below the comment;
the buffer is unchanged until you accept it with normal-mode `<M-;>`.

Acceptance replaces the whole comment node and leaves surrounding whitespace
and code untouched. Editing the buffer or moving the cursor invalidates the
preview. This action requires a Tree-sitter parser for the current buffer and
reports a warning when the cursor is not on a comment or no parser is
available. Comment replacements are requested only explicitly and are not
stored in the automatic-completion cache.

## Configuration

Common options are shown below. Omitted entries retain their defaults:

```lua
require("codex_complete").setup({
  enabled = true,
  auto_trigger = true,
  debounce_ms = 200,
  loading_indicator = true,
  ghost_text = false, -- Set to true to also draw suggestions inline.
  highlights = {
    suggestion = "CodexCompleteSuggestion", -- Black text by default.
    background = "CodexCompleteSuggestionBackground", -- Dark green; set to false for no background.
    existing_delimiter = "MatchParen",
  },
  context = {
    before_lines = 200,
    after_lines = 50,
    max_bytes = 24 * 1024,
    related = {
      enabled = true,
      timeout_ms = 150,
      max_bytes = 16 * 1024,
      max_snippets = 8,
    },
    lsp = { -- Language-server facts gathered before each request.
      enabled = true,
      timeout_ms = 150,
      max_completions = 40,
      max_hover = 3,
    },
    activity = { -- Rolling window of your recent edits.
      enabled = true,
      max_edits = 8,
      max_bytes = 4 * 1024,
    },
  },
  intent = { -- Background summary of what you are working on.
    enabled = true,
    idle_ms = 3000,
    min_edits = 3,
  },
  suggestion = {
    max_lines = 20,
    max_bytes = 8 * 1024,
  },
  codex = {
    command = "codex",
    model = "gpt-5.6-luna", -- Default completion model.
    effort = "low", -- Default reasoning effort.
    timeout_ms = 30 * 1000,
    prewarm = true, -- Start the next completion thread ahead of time.
    completion_tools = false, -- Let inline completions read files and skills.
  },
  keymaps = {
    accept = "<M-;>",
    trigger = "<M-s>",
    comment_trigger = "<leader>ac",
    comment_accept = "<M-;>",
    dismiss = false,
    toggle = "<leader>at",
    select_model = "<leader>am",
    select_effort = "<leader>ar",
  },
  -- Omit `filetypes` to use the built-in code and structured-data allowlist.
  sensitive_patterns = {
    "^%.env$", "^%.env%.", "credentials", "secrets?%.", "%.key$", "%.pem$", "id_rsa",
  },
  is_eligible = nil, -- Optional function(bufnr, is_manual) -> boolean.
  notify = true,
})
```

Set a keymap to `false` to leave it unmapped. Manual requests may be used in
editable filetypes outside the automatic allowlist, but sensitive filenames,
special buffers, and read-only buffers always remain blocked.

Related context uses language-server definitions, matching project buffers, and
bounded `rg` searches of unopened files. Unsaved buffer text takes precedence.
The collector caches snippets and checks source revisions before reuse. The
project root comes from an attached LSP workspace, Git, or the file directory.
Missing LSP support or `rg` does not prevent completion.

Local retrieval waits up to `context.related.timeout_ms` (150 ms by default).
Related code adds at most 16 KiB across eight snippets to the existing 24 KiB
current-buffer budget. Set `context.related.enabled = false` to disable this
local enrichment. These limits do not limit Codex's own file or skill reads.

### Speed

Inline completions are answered in a single model response. Codex is told not
to read files or load skills, because each read is another model round trip;
everything it needs is sent up front. Comment replacements still let Codex
inspect the project and apply skills. Set `codex.completion_tools = true` to
allow that for inline completions too: completing `///` above a Rust struct
can then trigger a documentation skill, at the cost of extra round trips.

With `codex.prewarm` enabled, the app server and the next completion thread
are started when you enter insert mode and again after each request, so a
request only has to start a turn.

### Language-server context

Before each inline request the plugin asks the attached language servers for
signature help at the cursor, the completion list for the word being typed,
hover text for up to `max_hover` identifiers earlier on the line, and nearby
diagnostics. Collection stops after `context.lsp.timeout_ms` and sends
whatever arrived. Set `context.lsp.enabled = false` to skip it.

### Recent edits and intent

The plugin keeps a rolling window of your last `context.activity.max_edits`
edits as small unified diffs, plus recently visited files, and sends them with
each request so Codex can continue what you are doing. Edits are recorded when
you leave insert mode, change text in normal mode, or write a buffer.

When you pause for `intent.idle_ms` after at least `intent.min_edits` new
edits, a separate background request reads that window and writes a short
summary of what you are working on. Later requests include it.
`:CodexCompleteIntent` shows the current summary. Background summaries run on
their own thread, do not delay completions, and count against your Codex
limits; set `intent.enabled = false` to turn them off.

`status().engine.context` reports retrieval time, source filenames, and cache
hits. `status().engine.duration_ms` reports the last request's total duration.
These diagnostics do not log source contents.

The built-in defaults use `gpt-5.6-luna` with `low` reasoning. Set
`codex.model` or `codex.effort` to override either value. Runtime model changes
last for the current Neovim session and can be reset to the configured value
with `:CodexCompleteModel!`.

Set `codex.effort` to the default reasoning effort. Runtime effort choices are
validated against the active model and reset with `:CodexCompleteEffort!`. If a
new model does not support the current effort, the plugin adopts that model's
advertised default. Model and effort changes cancel and clear older suggestions.

## Commands and Lua API

| Command | Lua function | Purpose |
| --- | --- | --- |
| `:CodexComplete` | `trigger()` | Request a completion now |
| `:CodexCompleteComment` | `trigger_comment()` | Generate code from the comment under the cursor |
| `:CodexCompleteEnable` | `enable()` | Enable requests |
| `:CodexCompleteDisable` | `disable()` | Cancel work and disable requests |
| `:CodexCompleteToggle` | `toggle()` | Toggle request handling |
| `:CodexCompleteDismiss` | `dismiss()` | Clear the current suggestion |
| `:CodexCompleteIntent` | `intent()` | Show the background summary of your recent edits |
| `:CodexCompleteModel` | `select_model()` | Select from available models |
| `:CodexCompleteModel {id}` | `set_model(id)` | Validate and select a model ID |
| `:CodexCompleteModel!` | `reset_model()` | Restore the configured default model |
| `:CodexCompleteEffort` | `select_effort()` | Select an effort supported by the active model |
| `:CodexCompleteEffort {level}` | `set_effort(level)` | Validate and select an effort |
| `:CodexCompleteEffort!` | `reset_effort()` | Restore the configured default effort |

`accept()` inserts a visible completion or applies a visible comment
replacement, while `status()` returns current
plugin, process, request, model, reasoning-effort, loading-indicator, intent,
and error state.
`list_models(callback)` retrieves the visible Codex model catalog and calls
`callback(error, models)` when it completes. `list_efforts(callback)` similarly
returns the active model's supported reasoning efforts.

## Privacy and safety

- Requests include bounded current-buffer text and relevant project snippets,
  with filenames and line ranges, language-server signature, completion,
  hover, and diagnostic text for the cursor, and diffs of your recent edits
  with the names of recently visited files. Background intent summaries send
  the same diffs and file names. Edits in sensitive files are not recorded. Comment requests also include the selected
  comment and replacement range. The local collector excludes sensitive
  filenames and generated directories and respects ignore rules in disk searches.
- Completion threads are ephemeral, run with a read-only sandbox and approval
  policy of `never`, with network access disabled. Inline completions instruct
  Codex not to read files; comment replacements and intent summaries may read
  project files, instructions, skills, and references. Codex is instructed not
  to modify files or run skill scripts. Local snippet filters do not govern
  Codex's own file reads.
- Completion threads use the active file's directory (Neovim's working directory
  for unnamed buffers).
- The plugin checks account state through the app-server protocol. It never
  reads, copies, or logs `~/.codex/auth.json`.
- Completion context is sent to OpenAI through the locally authenticated Codex
  CLI. Your ChatGPT workspace controls and Codex subscription limits still
  apply.

## Troubleshooting

- **No suggestion appears:** Run `:checkhealth codex_complete`, then try
  `:CodexComplete` to surface a request error directly.
- **Codex is not authenticated with ChatGPT:** Run `codex logout`, then
  `codex login` and select ChatGPT sign-in.
- **Automatic completion is unavailable:** Check the filetype allowlist and the
  buffer name against `sensitive_patterns`.
- **Protocol initialization fails:** Upgrade the Codex CLI and run the health
  check again.

## Development

```sh
make test
make check
```

Tests use a local mock app server and never require network access or real
credentials. `make check` also requires
[StyLua](https://github.com/JohnnyMorganz/StyLua) and
[Selene](https://github.com/Kampfkarren/selene).

An optional authenticated smoke check is available with
`nvim --headless -u NONE -l tests/manual_context_smoke.lua`. It sends synthetic
Rust completion requests and prints suggestions, read commands, and timing
metadata. Set `CODEX_COMPLETE_CASE=struct` or `docs` to select one case, or
`CODEX_COMPLETE_BASELINE=1` to compare with buffer-only context, or
`CODEX_COMPLETE_TOOLS=1` to let inline completions read files and skills. Ensure `codex` on PATH launches the app server without extra stdout.

## License

MIT
