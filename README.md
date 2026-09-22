> [!WARNING]
> This project is currently not stable

# compl.nvim

A small Neovim 0.10+ plugin that captures the current file and previews an insertion
as ghost text. Accept the whole suggestion or dismiss it. Supports multiline text,
custom Lua generators, and Codex App Server with your existing Codex login.

## Installation

### lazy.nvim

Add the plugin to your lazy.nvim plugin specification:

```lua
{
  'Lukas-Fohl/complete.nvim',
  name = 'compl.nvim',
  opts = {
    provider = 'codex',
  },
}
```

lazy.nvim will install the plugin and call `require('compl').setup(opts)`.

### Neovim package manager

Neovim 0.12+ includes the built-in `vim.pack` package manager. Add this to
`~/.config/nvim/init.lua`:

```lua
vim.pack.add({
  'https://github.com/Lukas-Fohl/complete.nvim',
})

require('compl').setup({
  provider = 'codex',
})
```

Install Codex CLI separately and run `codex login` in a terminal first. The plugin
uses Codex's stored authentication; a ChatGPT subscription login needs no API key.
Requests use the allowance/billing of that login. The current file's unsaved contents
are sent to Codex only when you trigger a suggestion.

`require('compl').setup()` without options uses the offline fixed-example provider.
Set `vim.g.mapleader` before setup if you use a custom leader key.

## Usage

Normal-mode mappings (the default leader is `\`):

| Key | Action |
| --- | --- |
| `<leader>cg` | Capture the file and request a suggestion. |
| `<leader>ca` | Accept the entire insertion; use `u` to undo. |
| `<leader>cd` | Cancel a pending request or dismiss its preview. |

While a suggestion is visible, normal-mode `<Tab>` and `<CR>` accept it, while
`<Esc>` dismisses it. These temporary, buffer-local controls are removed once the
suggestion is accepted, dismissed, or invalidated; an existing buffer-local mapping
is restored afterward. While the `… thinking` marker is visible, `<Esc>` cancels the
request and `<Tab>`/`<CR>` wait for the completed suggestion.

Configure both the persistent leader mappings and the temporary suggestion controls:

```lua
require('compl').setup({
  keys = {
    trigger = '<leader>cg',
    accept = '<leader>ca',
    dismiss = '<leader>cd',
    suggestion = {
      accept = { '<Tab>', '<CR>' }, -- A key or list of keys; false disables it.
      dismiss = '<Esc>',
    },
  },
})
```

## Configuration

All `setup()` options are shown below. Omitted options use the defaults shown here.

```lua
require('compl').setup({
  provider = 'codex', -- nil, 'stub', or 'codex'
  process = function(context)
    return context
  end,
  -- generate = function(context) ... end, -- use instead of provider = 'codex'
  keys = {
    trigger = '<leader>cg',
    accept = '<leader>ca',
    dismiss = '<leader>cd',
    suggestion = {
      accept = { '<Tab>', '<CR>' }, -- key, list of keys, or false
      dismiss = '<Esc>',            -- key, list of keys, or false
    },
  },
  codex = {
    command = 'codex',              -- executable or argv list
    timeout_ms = 60000,
    model = 'gpt-5.6-luna',         -- false inherits Codex's configured model
    effort = 'low',                 -- false inherits Codex's configured effort
    auto_start = true,
    stream = true,
    position = 'cursor',            -- or 'model'
    context = 'nearby',             -- or 'file'
    context_lines = 80,
    max_suggestion_lines = 8,       -- false removes the limit
    autonomous = false,
  },
})
```

`provider = 'stub'` and an omitted `provider` use the offline example suggestion.
`provider = 'codex'` and `generate` are mutually exclusive. `process` is optional and
can be used with either provider. `codex` options only apply to the Codex provider.
Persistent mappings can be a string or `false`; temporary suggestion mappings can be a
string, a list of strings, or `false`.

By default, suggestions appear at the cursor position captured on trigger.
The first suggestion line appears inline at that position. Additional
lines appear as virtual lines below it. Existing text after that position stays
visible on its original line during preview; accepting moves it after the final
inserted line. Previews grow as text streams in; acceptance is enabled only after
the final response is validated. Acceptance changes the buffer without saving the file.

While Codex is working, the cursor location shows a dim `… thinking` marker. It is
replaced by streamed code or cleared when the request finishes, is dismissed, or the
editor state changes. Customize its appearance through the `ComplThinking` highlight
group; it links to `DiagnosticHint` by default.

Moving the cursor, editing, entering insert mode, or leaving the buffer cancels
pending work and clears the preview. Triggering again replaces the request. Late
responses are ignored. Special and nonmodifiable buffers are skipped.

## Decision pipeline

- `context.lua` captures `{ file = { path, filetype, lines } }`, including unsaved
  contents. An unnamed file has an empty path.
- `processor.lua` receives a copy of this object and currently returns it unchanged.
- `init.lua` supplies the offline stub and connects the editor-facing layers.
- `providers/codex.lua` selects context, builds the prompt, streams text safely,
  and generates suggestions asynchronously through `transport.lua`.
- `ghost.lua` validates, renders, dismisses, and accepts suggestions.
- `init.lua` connects the stages and manages mappings, requests, and editor events.

Custom synchronous generators continue to work:

```lua
require('compl').setup({
  process = function(context)
    return context -- Add context processing here later.
  end,
  generate = function(context)
    return {
      text = '\n-- suggested line\n',
      position = { row = 0, col = #context.file.lines[1] },
    }
  end,
})
```

Return a non-empty `text` value. Use LF (`\n`) for newlines, including any trailing
newline. Positions use **zero-based rows and UTF-8 byte columns**.
The row must exist and the column must be on a character boundary within the line
or at its end. Omit `position` in custom generators to use the trigger cursor.
Suggestions insert text; they cannot replace or delete existing code.

Use either `provider = 'codex'` or a custom `generate`, not both. A custom `process`
works with either provider. The internal asynchronous provider interface is
`generate(context, callback, editor)` with `callback(error, suggestion)`; it returns
a cancellation function. The optional `editor` argument carries the absolute cursor
`position` and `on_partial(suggestion)` callback. Providers also expose `stop()`,
`warmup(callback)`, and `stats()`.

Set an individual persistent mapping to `false` to disable it. For temporary
suggestion controls, use a key, a list of keys, or `false`. The public `trigger()`,
`accept()`, and `dismiss()` functions can also be called directly after setup.
Customize `ComplGhostText` to change its appearance; it links to `Comment` by default.

## Speed settings

These defaults apply when `provider = 'codex'`:

```lua
require('compl').setup({
  provider = 'codex',
  codex = {
    model = 'gpt-5.6-luna',
    effort = 'low',
    auto_start = true,
    position = 'cursor',
    context = 'nearby',
    context_lines = 80,
    max_suggestion_lines = 8,
    autonomous = false,
    stream = true,
    timeout_ms = 60000,
  },
})
```

- `model` / `effort`: explicit request settings. Use a supported model/effort pair;
  setting either to `false` inherits that setting from Codex. An existing explicit
  model setting in your Neovim config still wins over these defaults.
- `auto_start`: schedule background initialization after setup, without blocking
  startup. No file content or generation request is sent during warmup. Set `false`
  to start on the first suggestion instead. Plugin-manager lazy loading still
  determines when setup runs.
- `position`: `'cursor'` makes Codex produce only insertion text and uses the captured
  cursor position locally. Set `'model'` to let Codex return a position within the
  supplied context instead.
- `context`: choose `'nearby'` (the default) to send a window around the cursor, or
  `'file'` to send the entire current file.
- `context_lines`: with `context = 'nearby'`, include this many lines before and
  after the cursor, plus the cursor line (at most 161 with the default). Set `0`
  for just the cursor line. Context always includes path, filetype, total line count,
  excerpt start row, and cursor. Absolute positions stay correct for cropped input.
  Capture and your `process` callback still receive the full file; cropping happens
  afterward. Extra fields added by your processor are preserved.
- `max_suggestion_lines`: prompt Codex for at most this many lines (8 by default). An overlong final
  response is rejected rather than inserted incompletely. Set it to `false` to remove the line
  limit. Newline-separated empty lines count, including a trailing empty line. This is a
  prompt/output check, not a server token budget or a guarantee of generation speed.
- `autonomous`: when `true`, ask Codex to infer the local intent and produce a cohesive,
  implementation-ready insertion. The default `false` requests the shortest useful local
  completion instead. In either mode, Codex cannot use tools, read files beyond the supplied
  context, or replace existing text. When `max_suggestion_lines` is not `false`, it also
  cannot insert more than that limit.
- `stream`: preview decoded text as it arrives. In cursor mode the fixed position
  allows early display; model-selected positions wait for the final response.
  Partial escapes and incomplete Unicode characters are held back. Partial previews
  cannot be accepted, and failures/cancellations clear them. Set `false` to wait for
  the final response in all modes.

Compared with earlier versions, Codex now defaults to Luna/low, starts in the
background, sends nearby code, inserts at the cursor, and asks for short local
completions. To restore earlier selection behavior use `model = false`,
`effort = false`, `auto_start = false`, `position = 'model'`, `context = 'file'`,
and `autonomous = false`.

## Latency measurements

Run `:ComplStats`, or inspect `require('compl').stats()`. Measurements are in
milliseconds and describe the latest request; no prompts or generated code are logged.

- `warmup.startup_ms`: background process initialization and authentication time.
- `warmup.auth_ms`: time spent validating the stored Codex account during warmup.
- `request.prepare_ms`: context selection and prompt encoding time.
- `request.startup_ms`: time this request waited for initialization (near zero if warm).
- `warmup.thread_ms`: reusable conversation-thread creation time.
- `request.first_token_ms`: elapsed request time to the first agent-message delta.
- `request.first_preview_ms`: elapsed request time to the first decoded preview update.
- `request.generation_ms`: elapsed time from sending the turn to completion.
- `request.total_ms`: total provider request duration, including preparation and setup.

The report also includes status, requested model/effort, sent line count, and prompt
byte count. First-token/preview fields are absent if no corresponding event arrived.
`first_preview_ms` measures delivery to the renderer, not screen-paint time. Compare
first and subsequent requests on similar files to identify where the wait occurs.
Streaming improves time to visible text; it does not shorten model generation itself.

## App Server lifecycle

One local `codex app-server --listen stdio://` process initializes in the background
by default and stays alive until reconfiguration or Neovim exit. No Node.js bridge
or listening network port is needed. Warmup creates one ephemeral conversation thread
with the developer instructions; each trigger starts a new turn in that thread and
requests structured output from the selected context. The thread is unsubscribed when
the provider stops; Codex controls when it unloads from memory.

Threads run in read-only mode with approvals disabled. The prompt requests only an
insertion and forbids tools; this is still the Codex agent, not a tool-free model API.
Interactive tool requests are declined or rejected and cancel the suggestion.
The plugin uses your stored Codex authentication and configuration, with model and
effort overridden by the plugin settings above.

Failures are shown as Neovim notifications. For authentication errors, run
`codex login`; for usage limits, check your Codex allowance. A timeout cancels work
and stops the connection; the next trigger restarts it. A crashed server also
restarts on the next trigger. Increase `codex.timeout_ms` if generation needs longer.
`codex.command` accepts an executable path or an argv list for a wrapper command.

Protocol integration targets Codex CLI **0.153.4**. Its App Server command is marked
experimental; future CLI changes may require updates. See the official
[App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Verification

From the plugin directory:

```sh
nvim --headless -u NONE -i NONE -l tests/compl.lua
nvim --headless -u NONE -i NONE -l tests/codex.lua
```

The Codex suite uses a Python 3 fake server and makes no model requests. Tests cover
rendering, insertion, undo, protocol framing, authentication/errors, reusable
conversations, timeouts, cancellation races, and server restart.
