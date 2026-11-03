# Spec: predictive code completion

Status: **implemented** (PREDICT, 2026-10-31). Ycode's inline completion
from a local model the user runs. The reference's own on-device model cannot
be used: it is encrypted and bound to the Mac (`codelm-format.md` §1,
`specs/simulator/runtime-downloads.md` §7 on branch `obs-runtime`). Ycode
therefore has its own backend. Ollama is the default (owner decision O3);
llama.cpp's `llama-server` and OpenAI-compatible servers are advanced
choices.

**Ycode decision** marks Ycode's own choices. Everything else follows
public documentation (level 1). The Evidence section lists the sources.

## 1. What follows the reference and what is Ycode's own

| Behaviour | Source |
|---|---|
| Suggestions appear inline in the editor as you type. They are whole statements and methods, based on the surrounding code. | Level 1: WWDC24 "Xcode essentials" (session 10181), Code completion chapter. |
| Tab accepts what is shown. Holding Option expands the whole prediction. Option-Tab accepts the whole prediction. | Level 1: the same session. |
| Accepting in smaller segments while holding ⌃ (Control). | Level 1: Xcode 26 release notes, Source Editor ▸ New Features (137459125). The size of a segment and the exact keys are not documented. **Ycode decision:** ⌃Tab accepts the next word (see §3.2). **Open question** for the dirty room. |
| Editor ▸ Show Predictive Completion, ⌃⌥Space. | Level 2: `reference-ui-5.md` §2.7 item 7, `reference-ui-4.md`. |
| A switch named "Predictive code completion" in the editing settings. | A public third-party article (Lickability, "Xcode predictive code completion") places it in Settings ▸ Text Editing ▸ Editing. Apple's own documentation found for this spec does not name it. **Open question:** the label and place in 27.1. |
| The reference's model runs on the Mac (Apple silicon, macOS 15 or later; not in a virtual machine). | Level 1: Xcode 16 release notes (116310768, 130449481, 129198328). Ycode has no such limit: the model runs wherever the user's server runs. |
| The reference's suggestions use context from the project; Xcode 16.3 widened it. | Level 1: Xcode 16.3 release notes (141363041). Ycode's context is in §4.1. |
| The reference steers a prediction by the item selected in the completion pop-up. | Level 1: Xcode 16.2 release notes (129624498, 138437280). **Not done** in Ycode: the ghost text hides while the pop-up shows (§3.3). |
| Grey ghost text, the debounce, Escape, typing through the suggestion, the drawing of extra lines, the status line. | **Ycode decisions** (§3). No public source describes them. **Open questions** for the dirty room: whether Escape dismisses, whether typing through keeps the suggestion, the delay, and whether suggestions are offered when the caret is in the middle of a line. |

## 2. Settings keys (the shared model)

`PredictiveCompletionSettings` (`YcodeCompletion`) is the only settings
model. Both IDEs, `ycode complete`, the MCP tool and the onboarding
(RUNTIME-ONBOARD) read and write it. It is stored as one JSON value (data)
under the user default **`Ycode.predictiveCompletion`**. Missing keys keep
their defaults, so a writer can set only some of them.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `false` | The switch. Off until the user or the onboarding turns it on. **Ycode decision:** Ycode bundles no model, so nothing is on by default. |
| `backend` | `"ollama"` \| `"llamaServer"` \| `"openAICompatible"` | `"ollama"` | Where suggestions come from. |
| `address` | string, optional | absent | The server address. When absent, Ollama uses **the coding assistant's Ollama address** (`Ycode.codingAssistant` → `ollamaURL`, default `http://127.0.0.1:11434`). The other backends use `http://127.0.0.1:9931` (llama-server's documented default port). |
| `model` | string | `""` | The model ID. `""` means: for Ollama, the first installed model whose `/api/show` `capabilities` include `insert` (it can fill in the middle); for the servers, their loaded model. No model name is built into Ycode. |
| `maxTokens` | int | 128 | The most tokens in one suggestion. |
| `debounceMilliseconds` | int | 250 | The pause in typing before a request. |
| `temperature` | number or `null` | 0.2 | `null` means the server's default. |
| `topP`, `topK`, `repeatPenalty` | number / int / number, optional | absent | Sampling. Absent means the server's default. `repeatPenalty` is sent as `repeat_penalty` (Ollama option, llama-server, and OpenAI-compatible servers that accept it). |
| `prefixTokens`, `suffixTokens`, `relatedTokens` | int | 1536, 512, 512 | The context budget (§4.1). Setting `relatedTokens` to 0 turns related snippets off. |
| `fimFormat` | `"auto"` \| `"qwen"` \| `"starCoder"` \| `"codeLlama"` \| `"deepSeek"` \| `"suffixFirst"` \| `"chat"` | `"auto"` | The prompt layout for an OpenAI-compatible server (§6.3). |
| `maxLines` | int | 12 | The most lines in one suggestion. |

API for other components: `PredictiveCompletionSettings.load(from:)`,
`save(to:)`, `effectiveAddress(assistantOllamaURL:)`,
`assistantOllamaURL(in:)`, `assistantOllamaModel(in:)`, and
`makeBackend(assistantOllamaURL:)`. In the macOS IDE,
`Preferences.predictiveCompletion` reads and writes the same value and
notifies open editors.

**Xcode preference import** (runtime-downloads.md §7.4).
`importXcodePreferences(_:)` maps the reference's keys from the domain
`com.apple.dt.Xcode`, `DVTTextEnablePredictiveCompletion` and
`DVTEnableOnDeviceCodePredictions`, onto `enabled`:

- It is on when every key that is present is true.
- It is off when one key that is present is false.
- With neither key present, nothing changes.

The backend, address and model are never imported, because the reference's
model cannot be used. Values may be booleans, numbers or "YES"/"NO" strings.
This spec describes no UI that runs the import. An onboarding or a settings
import calls the function with the values it read.

## 3. The macOS editor

### 3.1 Showing a suggestion

- The suggestion is drawn after the caret in the text color at 40 %
  opacity (**Ycode decision**).
- **Collapsed** (the default), the suggestion shows up to the end of its
  first line that has text. A suggestion that starts with a line break
  shows the next line too.
- **Holding Option** shows every line, as the reference documents.
- The first line goes on the caret's line. Whatever follows the caret on
  that line (closing brackets, or the rest of the line after Show
  Predictive Completion) is covered and drawn again to the right of the
  suggestion. The extra lines are drawn on a block filled with the
  background over the lines below, with a thin bar at its left edge.
  **Ycode decision:** the document's layout does not change, so nothing
  scrolls or reflows.
- The drawing is on a transparent view above the text view, because
  TextKit 2 draws text in fragment views. That view does not take clicks.

### 3.2 Keys

| Key | Action |
|---|---|
| Tab | Accepts what is shown (collapsed: the first line; while Option is held: all of it). |
| ⌥Tab | Accepts all of it. |
| ⌃Tab | Accepts the next segment: line breaks and spaces, then one run of word characters or one run of other characters. **Ycode decision** (§1). |
| Escape | Dismisses the suggestion and stops its request. |
| Typing | Typing the suggestion's next characters keeps the rest of it (no new request). Typing anything else, deleting, moving the caret, selecting, or showing the completion pop-up removes it. |
| ⌃⌥Space | Editor ▸ Show Predictive Completion: asks at once, wherever the caret is. |

Accepting inserts text through the text view, so it can be undone and the
suggestion's remaining text stays. Tab with no suggestion keeps its usual
meaning: placeholders, then indentation.

### 3.3 When Ycode asks

All of these are **Ycode decisions**:

- Ycode asks when the switch is on, after an edit that leaves a single
  caret and no selection, once typing pauses for `debounceMilliseconds`.
- It asks only when the rest of the caret line holds nothing but closing
  brackets, quotes, separators and spaces. In the middle of code, only
  Show Predictive Completion asks.
- Ycode does not ask while the language server's completion pop-up shows,
  or while there are several carets.
- A new request cancels the one before it. A request that is still
  streaming learns what was typed through its partial suggestion.

### 3.4 Status

When the backend cannot be used, the editor reports it to the window. The
activity view (toolbar) then shows "Predictive completion: \<message\>"
once, with a tooltip that holds the hint. For Ollama the hint is "Install
Ollama from ollama.com/download and open it (or run `ollama serve`), then
choose a model in Settings." No alert is shown.

- The notice stays out of the way of a build, a run or a preview.
- It goes away when a suggestion arrives.
- After "nothing answers", automatic requests wait 30 s.
- Show Predictive Completion always tries.

### 3.5 Settings

**Settings ▸ Editing** has the switch "Predictive code completion" (in the
When Editing group).

**Settings ▸ Editing ▸ Completion ▸ Predictive Code Completion** has these
rows:

- **Backend:** Ollama, llama.cpp server, or OpenAI-compatible server.
- **Address:** the placeholder shows the address that will be used. With
  Ollama and no address set, a note says that the coding assistant's
  address is used.
- **Model:** Automatic, followed by the models the last Test found. For
  Ollama, these are only the models with `insert`.
- **Test:** probes the backend (§6) and shows the result in a line below.
  If Ollama is not reachable, the line gives the install text, and a
  **Get Ollama…** button opens ollama.com/download in the browser.
- **Download a model** (Ollama only): a name field and a **Download**
  button. This is the only place where Ycode pulls a model (`/api/pull`,
  with progress). It happens only when the user asks, with the name the
  user typed.
- **Wait after typing (ms)**, **Most tokens**, **Temperature** (empty
  means the server's default).
- **Prompt format** (OpenAI-compatible only).
- The privacy note (§9).

## 4. The engine (`YcodeCompletion`, portable)

### 4.1 Context

`CompletionContext.make(text:caret:path:language:related:limits:)` builds
the context:

- **Prefix and suffix.** These are the text before and after the caret.
  The prefix is cut to `prefixTokens` and starts at a line start. The
  suffix is cut to `suffixTokens` and ends at a line end. The caret line is
  always kept whole.
- **Token estimate.** Tokens are counted as 3 UTF-16 units each. **Ycode
  decision:** there is no tokenizer round trip per keystroke.
- **Path and language.** The path is workspace-relative in the IDE. The
  language comes from the file extension.
- **Related snippets** (**Ycode decision**, the "neighbouring files"
  approach):
  - Each other open file is cut into 20-line windows.
  - Each window is scored by the Jaccard overlap between its identifiers
    and the identifiers in the 20 lines before the caret. Identifiers have
    at least 3 characters, and keywords are left out.
  - The best window per file is a candidate if its score is at least 0.1.
  - At most 3 snippets are kept, within `relatedTokens`.

### 4.2 Request

`PredictionRequest` carries the context, the model, `maxTokens`,
`temperature`, `topP`, `topK` and the FIM format. Every backend streams
its reply.

### 4.3 Shaping the output

`SuggestionShaper` decides what is shown. All of these are **Ycode
decisions**:

1. **Chat replies** lose their code fence, `<CURSOR>`, and a repeat of the
   caret line's text.
2. **Boundary.**
   - In the middle of a line, only the first line is kept.
   - Otherwise at most `maxLines` lines are kept. The suggestion stops:
     - before a line indented less than the caret line (the block
       ended);
     - before a Markdown fence;
     - after a line that closes what the suggestion opened, or the block
       the caret is in;
     - after the line that closes the brackets the caret line opened (the
       statement is complete);
     - at two blank lines in a row.
   - Once a boundary is reached, the request is cancelled. This saves
     generation time; §8 shows the `stoppedEarly` cases.
3. **Overlap.**
   - Trailing lines equal to the first lines after the caret line are
     dropped. For example, a `}` that is already there.
   - For a one-line suggestion, the end that the rest of the caret line
     already holds is dropped. For example, `print("a"|)` and a model's
     `")` become `"`.
4. **Rejection.** Nothing is shown when the suggestion is:
   - whitespace only;
   - the start of the following text;
   - nothing but the line above again (at a blank caret line).

### 4.4 Cache

`SuggestionCache` keeps up to 32 entries and drops the least recently used
one. An entry's key is made of:

- the last 512 characters of the prefix;
- the first 256 characters of the suffix;
- the backend, address and model.

A lookup can hit in two ways:

- an exact hit;
- a prefix that extends a cached one by text the cached suggestion starts
  with. That lookup returns the rest of the suggestion, so deleting and
  retyping costs no request.

### 4.5 The editor session

`PredictionSession` (`@MainActor`, no toolkit) is the state machine of §3:

- `textDidChange(snapshot, location:removed:inserted:)`
- `selectionDidChange(caret:length:)`
- `forceRequest(_:)`
- `dismiss()`
- `acceptText(.all | .shown | .line | .word)`
- `suggestion` (anchor and text)
- `status` (`idle`, `requesting`, `ready(model)`, or `unavailable(message, hint)`)
- `lastResult`, with its timings

The macOS editor drives it. The Linux editor drives the same object at L2
(§7.2).

## 5. Privacy

The code goes only to the address in the settings, and only while the
switch is on, or when `ycode complete` or the MCP tool asks.

- Every default address is the loopback interface (`127.0.0.1`), so with
  the defaults code never leaves the machine. It leaves only if the user
  enters a remote address.
- What is sent: the prefix and suffix windows (§4.1), the file's
  workspace-relative path, and up to three short snippets of other open
  files.
- Nothing is logged or stored. The only exception is the in-memory cache
  (§4.4).
- Ycode never downloads a model by itself. It never changes the server's
  settings: Ollama's `keep_alive` is not sent, so the server's own value
  applies.
- API keys are not supported for this feature. Ycode stores no secret for
  it.

## 6. Backends

### 6.1 Ollama (default)

This backend follows Ollama's public API documentation. It extends
`YcodeAssistant.OllamaProvider` (`OllamaProvider+Generate.swift`), the
same code the coding assistant uses.

- `GET /api/tags` lists the models. `POST /api/show {model}` gives
  `capabilities`. Ycode picks the first model with `insert` and remembers
  it per address until the model list changes.
- `POST /api/generate {model, prompt, suffix, stream: true, options:
  {num_predict, temperature, top_p, top_k}}` streams NDJSON:
  - `response` is text;
  - `done: true` ends the stream, with `eval_count` and the durations.

  With `suffix`, the model's own template builds the fill-in-the-middle
  prompt. For example, Qwen2.5-Coder's template uses `<|fim_prefix|>`,
  `<|fim_suffix|>` and `<|fim_middle|>`. Ycode never writes those tokens
  for Ollama.
- The template has no slot for other files. Related snippets therefore go
  before the prefix as line comments: `// From <path>:` followed by the
  lines (**Ycode decision**). This happens only for languages with a
  line-comment marker.
- `POST /api/pull {model, stream: true}` pulls a model, only from
  Settings ▸ Download.
- Errors:

  | Condition | Result |
  |---|---|
  | Nothing at the address | `unreachable` with the install hint |
  | HTTP 404 | `modelNotFound` |
  | No model with `insert` | `noModel` |

### 6.2 llama.cpp `llama-server` (advanced)

This backend follows llama.cpp's server README (MIT).

- `POST /infill {input_prefix, input_suffix, input_extra: [{filename,
  text}], prompt: "", n_predict, stream: true, cache_prompt: true,
  temperature, top_p, top_k}` streams server-sent events. Each event is
  `{content, stop}`.
- The server builds the FIM prompt from the model's GGUF tokens. When the
  model has `FIM_REPO` and `FIM_FILE_SEP` tokens, it uses the repo-level
  layout, with `input_extra` as the other files.
- `GET /v1/models` is used for Test and the model list.

### 6.3 OpenAI-compatible (advanced)

- `POST /v1/completions {model, prompt, max_tokens, stream: true,
  stream_options: {include_usage: true}, stop, temperature, top_p, top_k}`.
  The FIM prompt uses the model family's own published tokens:

  | Format | Prompt |
  |---|---|
  | `qwen` | `<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`, with `<|repo_name|>`/`<|file_sep|>` for related files |
  | `starCoder` | `<fim_prefix>…<fim_suffix>…<fim_middle>`, `<file_sep>` |
  | `codeLlama` | `<PRE> … <SUF>… <MID>` |
  | `deepSeek` | `<｜fim▁begin｜>…<｜fim▁hole｜>…<｜fim▁end｜>` |
  | `suffixFirst` | `[SUFFIX]…[PREFIX]…` |

  The format's special tokens are also the stop strings, at most 4 (the
  OpenAI API's limit).
- `auto` picks the format from the model ID: `qwen`, `starcoder` or
  `granite`, `codellama`, `deepseek`, `codestral`. Anything else uses the
  chat fallback, `POST /v1/chat/completions`. It sends an instruction to
  reply with only the code at `<CURSOR>` (the shaper strips fences).
- `GET /v1/models` is used for Test. A base address may or may not end in
  `/v1`.

The coding assistant's `ChatCompletionsProvider` now also sends
`stream_options.include_usage`. Before this change its streamed replies
carried no token usage (SIMPLESD-TRIAL's finding).

## 7. Linux and the command line

### 7.1 What works on Linux now

The whole engine builds and is tested on Linux: context, shaping, cache,
backends, session and settings. The Linux shell's editor is read-only
until L2 (`docs/PARITY.md` §5.9), so Linux has no ghost text yet. Two
entry points work today:

- **`ycode complete --file F --line L --column C`** prints the suggestion.
  - Options: `--backend ollama|llama-server|openai`, `--address`,
    `--model`, `--max-tokens`, `--temperature`, `--top-p`, `--top-k`,
    `--fim`, `--related <file>` (repeatable), `--raw` (the model's output
    before shaping), `--json` (suggestion, raw, model, firstTokenMs,
    totalMs, stoppedEarly), `--timing`.
  - The settings come from the user defaults, and the flags override
    them. The command works with the switch off.
  - Exit statuses: 0 for a suggestion, 1 for no suggestion, 64 for usage,
    65 for no such line, 66 for an unreadable file, 69 for an unusable
    backend.
- **MCP tool `complete`** (`ycode mcp`, now 29 tools): `{path, line,
  column, maxTokens?}` returns `{suggestion, backend, model, totalMs}`.

### 7.2 What L2 must call

These calls are also listed in `docs/PARITY.md` §5.9:

1. Keep one `PredictionSession` per editor. Set it up as follows:
   - `settings` from `PredictiveCompletionSettings.load(from:)` (reload it
     when the settings change);
   - `assistantOllamaURL` from `assistantOllamaURL(in:)`;
   - `onSuggestionChange` (redraw) and `onStatusChange` (the status line,
     with the same text as §3.4).
2. After each edit, call `textDidChange` with a `Snapshot` and the edit.
   The `Snapshot` holds the text, the caret as UTF-16, the selection
   length, the workspace-relative path, the language and the other open
   files. The edit is given as UTF-16 location, removed length and
   inserted text, and it must arrive before the caret-move notification.
   Ignore caret moves during the edit, then call `selectionDidChange`.
3. Handle the keys before the editor's own bindings: Tab, ⌥Tab, ⌃Tab
   (`acceptText(.shown | .all | .word)`, then insert the text at the
   anchor as an ordinary undoable edit), Escape (`dismiss()`), and
   ⌃⌥Space (`forceRequest`). Option held toggles the expanded drawing.
4. Draw `suggestion.text` from `suggestion.anchor` in the `Canvas` layer,
   as described in §3.1: collapsed with `PredictionSession.collapsed`,
   covering and redrawing the rest of the caret line, with extra lines on
   a filled block. Also add the Settings rows of §3.5 to the shell.

## 8. Tests and measurements

- **Unit tests** (`YcodeCompletionTests`, macOS and Linux):
  - context cuts, line and column offsets, related snippets;
  - every shaping rule, with streaming and early stop;
  - the cache;
  - settings storage, sharing the assistant's Ollama address, and the
    Xcode preference import;
  - the FIM formats;
  - each backend against `StandInServer`, a stand-in on 127.0.0.1 that
    speaks Ollama, `/infill` and the OpenAI endpoints;
  - the session: debounce, typing through, typing ahead of a streaming
    request, accepting, an unreachable backend with back-off, off;
  - `ycode complete`.
- **macOS UI tests** (`PredictiveCompletionUITests`): real key events into
  a source editor with a stand-in backend. They check:
  - the ghost text appears and is drawn (pixels change);
  - Option expands it;
  - Tab accepts the shown line, and the rest stays;
  - Escape dismisses it;
  - typing through needs no new request;
  - ⌃Tab takes a word and ⌥Tab takes all;
  - typing something else, or moving the caret, drops it;
  - Tab still indents when there is no suggestion;
  - the menu action asks in the middle of a line;
  - off sends nothing;
  - the Settings rows, Test, the "Get Ollama…" row, and switching the
    backend;
  - the activity-view text.
- **End to end on the Mac** (2026-10-31). The setup was:
  - Ollama 0.40.13 at 127.0.0.1:11434, model `qwen2.5-coder:latest`
    (7.6B, Q4_K_M, Apache-2.0, capability `insert`). Ycode chose it
    automatically.
  - `ycode complete --json` on six Swift samples, with defaults
    (temperature 0.2, 128 tokens).
  - The Mac was heavily loaded by other agents.

  Times are from sending the request; "first" is time to first token.

  | Case | Suggestion | First / total (ms) |
  |---|---|---|
  | `func total() -> Double {` empty body | `items.reduce(0) { $0 + $1.price * Double($1.quantity) }` | 4882 / 5287 (cold: model load), then 118 / 496 |
  | `return ` in `fibonacci` | `fibonacci(n - 1) + fibonacci(n - 2)` | 59 / 346 |
  | empty `Button("Increment") { }` body | `count += 1` (stopped early) | 55 / 189 |
  | `try JSONDecoder().decode(` | `User.self, from: data)` (stopped early) | 42 / 160 |
  | `switch self` after `case .north: return .south` | the other three cases (stopped early) | 44 / 617 |
  | `numbers.filter { ` at the end of the file | `$0 % 2 == 0 }` (stopped early) | 37 / 236 |

  All six were correct and were accepted as they stand. In the first run,
  before the statement-complete and fence rules (§4.3), the last case ran
  on into prose and a Markdown fence (2969 ms). The `decode(` case also
  took a second line. Both rules are now covered by unit tests.
- **x86 workstation.** No Ollama is installed there. Building llama.cpp
  from source was blocked for agents, so the owner builds it. No model
  test ran on the x86. The x86 suite (engine tests included) ran as usual.
  To try `llama-server` there, the owner runs:

  ```sh
  # llama.cpp (MIT), CUDA build, in the owner's own folder
  git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
  cmake -B build -DGGML_CUDA=ON && cmake --build build --config Release -j
  # A FIM model, Apache-2.0, 1.65 GB (8.1 GB for the 7B Q8_0 file)
  mkdir -p ~/Ycode-predict/models && curl -L -o ~/Ycode-predict/models/qwen2.5-coder-1.5b-q8_0.gguf \
    https://huggingface.co/ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF/resolve/main/qwen2.5-coder-1.5b-q8_0.gguf
  # loopback only
  build/bin/llama-server -m ~/Ycode-predict/models/qwen2.5-coder-1.5b-q8_0.gguf \
    --host 127.0.0.1 --port 9931 -ngl 99 -c 4096 -b 1024 -ub 1024 --cache-reuse 256
  # then
  ycode complete --backend llama-server --file Sample.swift --line 6 --column 9 --json
  ```

## 9. Models (suggested, never bundled)

Ycode bundles no model and downloads none by itself. These are suggestions
with OSI licences and published FIM tokens. The user pulls one in Ollama
(`ollama pull <name>`, or Settings ▸ Download), or downloads a GGUF from
the publisher for `llama-server`.

| Model | Licence | Notes |
|---|---|---|
| Qwen2.5-Coder 0.5B, 1.5B, 7B, 14B (base or instruct) | Apache-2.0 (each size's model card) | Qwen FIM and repo-level tokens. 1.5B is light enough for any machine. 7B gave §8's results. **The 3B size is not Apache-2.0** (Qwen Research licence): do not suggest it. |
| IBM Granite Code (3B, 8B base) | Apache-2.0 | StarCoder-style FIM tokens. |

Not suggested as defaults, because their licences are not OSI-approved:
StarCoder2 (BigCode OpenRAIL-M), Code Llama (Llama licence), DeepSeek-Coder
(DeepSeek licence), Codestral (Mistral non-production licence). Apple's
research models (for example SimpleSD and DiffuCoder; Apple ML Research
licence) are never a default. A user who runs one can point Ycode at that
server.

## 10. Open questions (for the dirty room)

1. The size of the ⌃ segment, and the keys used for it, in 27.1.
2. Whether Escape dismisses, whether typing through keeps the suggestion,
   and the delay before a prediction appears.
3. Whether predictions appear when the caret is in the middle of a line,
   and how the reference draws extra lines (inline reflow or overlay).
4. The settings label and its place in 27.1 (Text Editing ▸ Editing, or
   an Intelligence pane).
5. How the completion pop-up's selection steers the prediction.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Inline whole-statement predictions; Tab accepts what is shown; hold Option to expand; Option-Tab accepts all | 1 | WWDC24 session 10181 "Xcode essentials", Code completion chapter (14:19) |
| Partial accept "by holding the ^ key" | 1 | Xcode 26 release notes, Source Editor ▸ New Features (137459125) |
| Requirements (Apple silicon, macOS 15, no VM); a model trained for Swift and Apple SDKs | 1 | Xcode 16 release notes (116310768, 130449481, 129198328) |
| Steering by the completion pop-up; widened project context | 1 | Xcode 16.2 release notes (129624498, 138437280); 16.3 (141363041) |
| Settings ▸ Text Editing ▸ Editing switch | public third-party article | Lickability, "Xcode predictive code completion" |
| Show Predictive Completion ⌃⌥Space | 2 | `reference-ui-5.md` §2.7 |
| `DVTTextEnablePredictiveCompletion`, `DVTEnableOnDeviceCodePredictions` | 2 | `runtime-downloads.md` §7.1, §7.4 (branch `obs-runtime`) |
| The reference's model cannot be used | 2, 3 | `codelm-format.md` §1 |
| Ollama `/api/generate` `suffix`, `/api/show` `capabilities`, `/api/tags`, `/api/pull` | 1 | Ollama API documentation (MIT); checked against Ollama 0.40.13 on loopback |
| llama-server `/infill`, `input_extra`, repo-level FIM layout, `/v1/models`, port 9931 | 1 | llama.cpp `tools/server/README.md` (MIT) |
| FIM token layouts | 1 | each model family's model card |
| Model licences | 1 | Hugging Face model cards (Qwen2.5-Coder sizes, ggml-org GGUF repos, IBM Granite Code, StarCoder2) |
| Everything marked **Ycode decision** | — | Ycode's own design |

No Apple binary was inspected and Xcode was not run for this spec.
