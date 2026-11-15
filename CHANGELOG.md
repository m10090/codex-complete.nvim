# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Removed

- The built-in lualine component.

### Changed

- Inline completions are answered in a single response without file or skill
  reads; set `codex.completion_tools = true` to restore them.
- The default debounce is now 200 milliseconds.
- The inline loading spinner is now off by default; set
  `loading_indicator = true` to restore it.
- Completions that repeat text before the cursor or contain only whitespace
  are discarded.
- Inline ghost text is now off by default; set `ghost_text = true` to restore
  it. Suggestions are offered through the completion menu instead.
- Suggestion ghost text now defaults to black text on a dark green background.
- The default completion model is now `gpt-6-luna` with low reasoning.

### Added

- Pre-started completion threads, so a request only starts a turn.
- Language-server signature help, completions, hover text, and diagnostics in
  the request context.
- A rolling window of recent edits and visited files in the request context.
- Background intent summaries of recent edits, with `:CodexCompleteIntent`.
- The nvim-cmp menu opens with the Codex entry when a suggestion arrives at a
  position where nvim-cmp did not ask for completions.
- Codex completion entries carry their own marker, with a `cmp_format` helper
  that gives them a dedicated kind in nvim-cmp.
- Cached project briefs sent with every completion, with
  `:CodexCompleteProject`.
- A null-ls (none-ls) completion source that offers the current suggestion to
  nvim-cmp and other LSP completion clients.
- Tree-sitter comment prompts with explicit normal-mode triggering, virtual
  replacement previews, and atomic acceptance over the comment range.
- Configurable normal-mode mappings for toggling suggestions and opening the
  model and reasoning-effort pickers.
- Runtime model and reasoning-effort selection with pickers, direct commands,
  reset commands, Lua APIs, compatibility handling, and session status.
- Subscription-authenticated Codex app-server client.
- Automatic single- and multiline inline completions.
- Bounded current-buffer context and sensitive-file exclusions.
- Configurable controls, commands, health checks, and cancellation.
- Cross-platform mocked protocol and Neovim test coverage.
