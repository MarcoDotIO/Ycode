# Coding assistant

Ycode modules: `YcodeAssistant` (platform-neutral: providers, conversations,
prompt building, change proposals, secret storage, OpenAI sign-in, the
JSON-RPC layer, the ACP client; builds and tests on Linux), `YcodeMCP`
(platform-neutral: the Ycode MCP server and its tools, `ycode mcp`; §10), `YcodeSubprocess` (`StreamingSubprocess`),
`YcodeIDECore` (`Assistant/CodingAssistantModel`, `CodingAssistantServices`:
the window's assistant, shared by both IDEs), `YcodeUI` (the macOS IDE:
`CodingAssistantViewController`, `ConversationView`, `NewConversationPrompt`,
`ProposalReviewController`, `WorkspaceWindowController+CodingAssistant`,
`+AgentMode`, `App/CodingAssistantSettingsPane`), and the Linux IDE
(§11: `YcodeIDEShell/ShellAssistantModel`, `WorkspaceShellModel+Assistant`;
`ycode-ide/AssistantPane`, `AssistantTranscript`, `AssistantReviewSheet`,
`SettingsPaneCodingAssistant`, `ShellDriver+Assistant`).

The assistant answers questions about the user's code and proposes
changes. It talks to a model through one of six back ends. It never writes
a file on its own: every proposed change is shown as a comparison and is
applied only when the user accepts it.

## 1. What follows the reference and what is Ycode's own

| Part | Source |
|---|---|
| Where it lives: the toolbar's Navigators / Coding Assistant control, ⌘0, the New Conversation toolbar button, File ▸ New ▸ Conversation ⌃⌘H, Navigate ▸ Jump to Next Active Conversation ⌃⌘K, Editor ▸ Show Coding Tools ▸ Explain / Document / Generate a Playground / Generate a Preview | `reference-ui-5.md` §2.2, §2.6, §2.7, §4.1, §4.3 (level 3) |
| A conversation list, a transcript, a message field with Stop, attachments, conversations named after their first prompt, proposals the user applies, a separate settings pane for providers, providers that speak `/v1/models` + `/v1/chat/completions`, a locally hosted provider identified by its address | Apple's public Xcode documentation: "Setting up coding intelligence", "Writing code with intelligence in Xcode", "Using coding intelligence in the source editor" (level 1) |
| The Document, playground and preview tools' behavior (DocC comments for the selection; a `#Playground` block; a `#Preview`) | "Using coding intelligence in the source editor" (level 1) |
| Everything else: the pane layout, the providers' wire use, the response format for proposals, prompt budgeting, storage, the review sheet, the settings rows and their names | Ycode's own design |

Apple's service names are not used (`AGENTS.md` rule 5). The settings pane
is "Coding Assistant", not the reference's "Intelligence".

## 2. Provider protocol

Every back end implements `AssistantProvider`:

- `availability()` → `ready(models)` | `notRunning(hint)` | `noModels(hint)`
  | `notInstalled(hint)` | `signedOut(hint)` | `failed(message)`. The hint
  is the text the pane shows, with the command to run where there is one.
- `contextWindow(model:)` → tokens, when the back end reports it.
- `send(ChatRequest)` → an `AsyncThrowingStream` of `text(delta)`,
  `activity(line)` (what an agent tool is doing) and `finished(usage)`.
  Ending the iteration (the Stop button cancels the task) closes the HTTP
  connection or interrupts the subprocess.
- Errors are `AssistantError` values with a description and, where one
  exists, a recovery suggestion; the transcript shows both under the
  response. A stopped response shows "Stopped.".

`ChatRequest` carries the model, the instructions (§5.1), the messages
(earlier turns, then the new user message with its context), the context
size the prompt was built for, and the workspace folder.

## 3. Back ends

### 3.1 Ollama (local)

Default address `http://127.0.0.1:11434`, set in Settings. Ollama's native
API:

- `GET /api/tags` → `models[].name`. No answer: "not running", with "open
  the Ollama app, or run `ollama serve`". Empty list: "no models", with
  "run `ollama pull qwen2.5-coder`".
- `POST /api/show {model}` → `model_info["<arch>.context_length"]`.
- `POST /api/chat {model, messages: [system, …], stream: true, options:
  {num_ctx}}` → NDJSON lines; `message.content` is text, `done: true` ends
  (`prompt_eval_count`, `eval_count` as usage), `error` fails. HTTP 404
  "model … not found" becomes "run `ollama pull <model>`". `num_ctx` is the
  context the prompt was built for (§5.2), so the server does not cut the
  prompt.

### 3.2 llama.cpp (`llama-server`, local)

Default address `http://127.0.0.1:9931` (llama-server's documented default
port), set in Settings; an optional API key (sent as `Authorization:
Bearer`) for a server started with `--api-key`.

- `GET /v1/models` → `data[].id` (with `meta.n_ctx_train`). 503 means the
  model is still loading; 401 asks for the key.
- `GET /props` → `default_generation_settings.n_ctx`, the running context.
- `POST /v1/chat/completions {messages, stream: true[, model]}` → server-sent
  events; `choices[0].delta.content` is text, `usage` is kept, `data:
  [DONE]` ends. A stream that ends without `[DONE]` is "incomplete".

Any server with these two endpoints works here (the same pair the
reference requires of an added provider).

### 3.3 OpenAI

Base address `https://api.openai.com/v1` (changeable, for proxies and
tests). Models come from `GET /v1/models` at run time; Ycode names none.
Both documented shapes are read: `{"models": [{slug, display_name,
visibility}]}` (plan usage: only `visibility == "list"`, `display_name`
shown, `slug` sent) and `{"data": [{id}]}` (API keys: GPT models first,
newest names first). GPT-6 and GPT-6.1 appear when the account offers
them.

Requests use the Responses API: `POST /v1/responses {model, instructions,
input: [{role, content}], store: false, stream: true}`. No `system` input
items (the instructions go in `instructions`), and none of the fields plan
usage rejects (`max_output_tokens`, `temperature`, `previous_response_id`,
…). Events: `response.output_text.delta` → text; `response.completed` →
done with `usage`; `response.failed` → its `error.code`;
`response.incomplete` → "stopped early (reason)"; `error` → failure. A
stream without `response.completed` is incomplete.

Two ways to authorize, chosen in Settings:

1. **Sign in with ChatGPT** (default). OpenAI documents a sign-in for
   open-source and locally hosted apps that lets them call the Responses
   API on the user's ChatGPT plan ("ChatGPT plan usage",
   developers.openai.com/siwc/token-sharing-open-source). Ycode, an
   open-source app, uses exactly that flow:
   - Authorization Code with PKCE (S256) in the system browser, redirect to
     a loopback listener `http://127.0.0.1:<free port>/auth/callback`
     started before the browser opens (only the port varies between
     sign-ins).
   - Authorize URL `https://auth.openai.com/api/accounts/authorize` with
     `client_id`, `agent_name_hint=Ycode` (first sign-in only),
     `ext_agent_host_id`, `response_type=code`, `redirect_uri`, `scope=openid
     profile email offline_access resource.invoke chatgpt.tokens.use.direct`,
     `resource=https://api.openai.com/v1`, `state`, `nonce`,
     `code_challenge_method=S256`, `code_challenge`; on later sign-ins
     `login_hint` (the saved email).
   - **Client registration.** The first sign-in sends
     `client_id=dynamic_agent_client`; OpenAI registers Ycode for that user
     and returns the issued `client_id` on the callback. Ycode keeps it and
     uses it for every later sign-in, token exchange and refresh. There is
     no client ID to type and no client secret. Ycode never uses another
     application's client ID (for example the Codex CLI's) and never sends
     `dynamic_agent_client` to the token endpoint.
   - The host ID is `urn:uuid:<random UUIDv4>`, made once per Mac and kept;
     it identifies nothing about the user.
   - Callback checks: `state` must match; `error=access_denied` stops
     ("Sign-in was cancelled."); a first sign-in without an issued
     `client_id` (or with the placeholder) is incomplete; a returning
     sign-in naming a different client is rejected.
   - Token exchange: `POST https://auth.openai.com/api/accounts/oauth/token`,
     form-encoded `grant_type=authorization_code, client_id, code,
     code_verifier, redirect_uri, resource`.
   - ID token: issuer `https://auth.openai.com`, audience the issued client
     ID, not expired (2-minute leeway), the attempt's nonce, a subject. On
     macOS the RS256 signature is verified with the keys at `jwks_uri` from
     `/.well-known/openid-configuration`. On Linux the token is accepted on
     the strength of the direct TLS exchange (OpenID Connect Core
     §3.1.3.7, step 6). A returning sign-in must be the same subject.
   - The grant must include `chatgpt.tokens.use.direct`; without it the
     sign-in is kept but OpenAI shows "ChatGPT plan usage isn't enabled for
     this app" with the way out (sign in again and allow it, or use an API
     key). Nothing switches billing silently.
   - Access tokens are refreshed when they expire within two minutes, or
     once after a 401: `grant_type=refresh_token, client_id, refresh_token,
     resource`, serialized so the rotating refresh token is never used
     twice; the newest refresh token replaces the old. `invalid_grant`,
     `invalid_refresh_token`, `token_expired`, `refresh_token_expired`,
     `refresh_token_invalidated`, `refresh_token_reused` clear the tokens
     ("sign in again"); a network failure keeps them.
   - Sign Out revokes the refresh token at the discovery document's
     `revocation_endpoint` (`token`, `token_type_hint=refresh_token`,
     `client_id`; retried on 5xx), then deletes the tokens. The registration
     and host ID stay. If revocation is not confirmed, the pane says so and
     points to disconnecting Ycode in ChatGPT settings.
   - Error codes map to the documented guidance: usage limit (429) → "Check
     your usage in ChatGPT settings"; usage or user unavailable (503) → "try
     again shortly"; not eligible, route not supported, scope not
     authorized → explained, no retry; unsupported capability → explained;
     invalid user → "sign in again".
   - The composer shows "Using ChatGPT plan · Manage usage in ChatGPT
     settings" while this back end is chosen. The first successful sign-in
     with plan usage shows "You're using your ChatGPT plan" once.
2. **API key.** The user pastes a key in Settings; it is stored in the
   keychain and sent as `Authorization: Bearer`. Requests are billed to the
   key's organization.

### 3.4 Agent tools: Claude Code, Codex, Antigravity

The user installs and signs in to these tools themselves. Ycode only runs
each tool's documented headless mode as a subprocess and reads its
documented event stream:

| Tool | Command line | Events read |
|---|---|---|
| Claude Code (`claude`) | `-p --output-format stream-json --verbose --include-partial-messages --permission-mode plan --tools Read,Grep,Glob --disallowedTools mcp__* --strict-mcp-config --safe-mode --no-session-persistence --permission-prompts none [--model M]`; the prompt on standard input | `stream_event` / `content_block_delta` / `text_delta` (text; subagent messages ignored), `assistant` `tool_use` blocks (activity), `system/api_retry`, `result` (`is_error`, `result`, `usage`) |
| Codex (`codex`) | `exec --json --sandbox read-only --ephemeral --skip-git-repo-check --color never -C <workspace> [-m M] -`; the prompt on standard input | `item.started` (`command_execution`, `file_change` → activity), `item.completed` `agent_message` (text, whole), `turn.completed` (`usage`), `turn.failed`, `error` |
| Antigravity CLI (`agy`) | `-p <prompt> --output-format stream-json --mode plan --sandbox --disable-slash-commands [--model M]` (its print mode takes the prompt as the argument) | `step_update` `text_delta` (text), `tool` steps (activity), `result` (`status`, `response`, `error`, `usage`) |

Rules:

- **Read-only.** Each runs in its planning or read-only mode, with its own
  file-editing tools unavailable (Claude Code: only Read, Grep, Glob, plan
  mode, no MCP tools, no hooks or project MCP servers; Codex: the read-only
  sandbox; Antigravity: plan mode and the terminal sandbox). The working
  directory is the workspace folder. They are asked, through the same
  instructions as every back end (§5.1), to answer with proposals, which
  Ycode shows for review.
- **Authentication stays in the tool.** Ycode does not read, copy or parse
  the tools' credential, token or configuration files and does not change
  them. A tool that is not signed in fails with its own message; Ycode
  adds "Run it once in Terminal to sign in". Ycode never answers a tool's
  prompts.
- **Finding them.** PATH, then `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`, `~/bin`, `~/.npm-global/bin`, `~/.bun/bin`,
  `~/.volta/bin`, `~/.claude/local`, `~/.codex/bin`, `~/.antigravity/bin`,
  `/usr/bin`, and each `~/.nvm/versions/node/*/bin` (newest first). A path
  set in Settings replaces the search. The tool's own folder is put first
  on the child's PATH (tools installed with Node need `node` there).
- **Models.** "Default" (the tool's setting) plus Claude Code's documented
  aliases (sonnet, opus, haiku); for Codex and Antigravity a model name can
  be typed in Settings.
- **Stop** sends SIGINT (Claude Code ends its turn on SIGINT), SIGTERM
  after 2 s, SIGKILL after 2 s more. All subprocess work runs off the main
  thread.
- The flattened prompt (§5.1) goes to the tool; earlier turns are included
  in it (no tool session is kept: `--no-session-persistence`,
  `--ephemeral`).

### 3.5 Output limit, sampling, cut-off replies (Ycode)

Added after the SimpleSD trial against a real `llama-server`. Before this
section, one reply looped for 32.5k tokens over 867 s, until the context
was full. Also, a reply cut off by the server looked complete, and streamed
replies carried no token usage. These are **Ycode decisions**; the request
fields are each server's documented API.

- **Settings** (`AssistantSettings.generation`, `GenerationOptions`):
  - Most output tokens: default **4,096**. Empty means no limit.
  - Temperature, top P, top K and repeat penalty: not set by default. A
    value that is not set is not sent, so the server's default applies.
- **Requests:**

  | Server | Fields sent |
  |---|---|
  | llama.cpp (`/v1/chat/completions`) | `max_tokens`, `temperature`, `top_p`, `top_k`, `repeat_penalty`, and always `stream_options: {include_usage: true}` |
  | Ollama (`/api/chat`) | `options.num_predict`, `temperature`, `top_p`, `top_k`, `repeat_penalty` |
  | OpenAI (Responses) | `max_output_tokens`, `temperature`, `top_p` (the API has no top K or repeat penalty) |

  Agent tools and ACP agents ignore these settings.
- **Cut-off replies.** A server can report that a reply stopped at the
  output limit:
  - `finish_reason: "length"` in a streamed chunk (llama.cpp);
  - `done_reason: "length"` (Ollama);
  - `response.incomplete` with reason `max_output_tokens` (OpenAI). Before
    this change that event was an error.

  The provider then sends `ChatEvent.truncated`, followed by `.finished`.
  The conversation marks the reply `isCutOff`. The transcript shows one
  secondary line, "The reply was cut off at the output limit (Settings ▸
  Coding Assistant ▸ Most output tokens).", and a small **Continue**
  button. Continue sends "Continue exactly where your last reply stopped.
  Do not repeat anything." in the same conversation.
- **Usage.** llama.cpp's final chunk (`choices: []`, `usage`) is read for
  the token counts.
- **Predictive completion** has its own limits: `maxTokens`, temperature,
  top P, top K and repeat penalty (`predictive-completion.md` §2).

## 4. The Coding Assistant pane and commands

- **Showing it.** ⌘0, View ▸ Navigators ▸ Show Coding Assistant, or the
  toolbar's Coding Assistant segment shows the pane in the left area
  (`reference-ui-5.md` §4.1 is unchanged: clicking the selected segment
  hides the area). The assistant is created the first time it is shown or
  used, and then checks every back end.
- **Header** (`reference-ui-6.md` §9.2–§9.3). "New Conversation" with a
  chevron and "New Group". The chevron's menu: the heading "Model
  Providers", then one row per back end; a ready one starts a
  conversation with it, one that is not set up shows its hint and "Set
  Up" (Settings ▸ Coding Assistant). The button part starts a
  conversation with the chosen back end, or opens the menu when none is
  usable.
- **Conversation list.** An outline: groups (made with New Group; each
  with its conversations), the conversations outside any group, then
  "Archive", always last. Conversations are newest first, with a
  speech-bubble icon (a different one while responding). Double-click or
  the context menu renames; the context menu moves a conversation to a
  group, archives it or moves it out of the archive, and deletes it;
  dragging onto a group, Archive or the list does the same. A deleted
  group's conversations go to the top level. A new conversation is titled
  "New Conversation" until its first prompt (the first line, at most 48
  characters). An untouched new conversation is reused.
- **Model pull-down.** Beside the message field, titled "Provider ·
  Model": each back end with its state ("not running", "no models", "not
  installed", "not signed in", "unavailable"), its models under it (the
  current one checked), then Check Again and Coding Assistant Settings….
  Choosing a model sets the back end and the model.
- **Status.** When the chosen back end is not usable, a note above the
  transcript gives its hint, "Use <ready back end>" buttons (up to three),
  Check Again and Settings…. With no usable back end at all:
  "The coding assistant needs a model. Use one of these: Ollama (install,
  then `ollama pull qwen2.5-coder`); llama.cpp (`llama-server -m
  <model>.gguf`); OpenAI (sign in with ChatGPT or enter an API key); Claude
  Code, Codex or the Antigravity CLI (install one and sign in to it once in
  Terminal)."
- **Transcript.** Each message shows who wrote it ("You", or "<Provider> ·
  <Model>"), its attachments, an agent tool's latest activity lines, then
  the text: prose with inline Markdown (code spans, emphasis), and fenced
  code blocks in a monospaced box with Copy. A block that is a proposal
  (§5.3) is titled "Proposed: …" and has Review… and, once decided,
  "Applied" or "Rejected". While a response streams, its text grows
  (updates are coalesced every 50 ms); before the first text, a spinner.
  Errors show in red under the text; "Stopped." in grey.
- **Message field.** Return sends; ⇧Return or ⌥Return adds a line. The
  paperclip menu attaches the current file or the selection (chips above
  the field; ✕ removes one). The button reads Send, or Stop while the
  selected conversation's response runs; Stop cancels it.
- **Commands.**
  - File ▸ New ▸ Conversation ⌃⌘H: show the pane, start a conversation,
    focus the field. Conversation in New Tab ⌃⌥⌘H / in Editor Pane
    ⌃⌥⇧⌘H: a new conversation's transcript and message field in a new
    editor tab / the next editor pane ("Conversations › <title>" in the
    jump bar). Always enabled.
  - The toolbar's New Conversation: the prompt popover of
    `reference-ui-6.md` §9.4; sending starts a conversation in the pane.
  - Navigate ▸ Jump to Next Active Conversation ⌃⌘K: selects the next
    conversation after the selected one (wrapping) whose response is
    running, and shows the pane. Enabled only while one is running.
  - Editor ▸ Show Coding Tools ▸ Explain, Document, Generate a Playground,
    Generate a Preview: start a new conversation titled "<Tool>
    <file>:<lines>" (or "<Tool> <file>") with the selection attached (or
    the whole file when nothing is selected), send the tool's prompt and
    show the pane. Enabled when a source editor shows an editable file and
    a back end is usable (until the back ends are first checked, assumed);
    Document and Generate a Playground need a Swift file; Generate a
    Preview a Swift file that mentions SwiftUI.
  - Show Coding Tools… ⌥⌘0 keeps showing the code actions at the caret
    (§9).
- Conversations and groups are saved per workspace in
  `~/Library/Application Support/Ycode/Conversations/<hash of the
  workspace path>.json` (never inside the workspace) as `{conversations,
  groups}`; a conversation carries its `groupID` and `isArchived`. Files
  holding a plain list of conversations (before groups) are read. Saves
  are written in order. A response that was streaming when they were
  saved is saved as "Interrupted.".

## 5. Prompts and proposals

### 5.1 Instructions

Every request starts with Ycode's instructions: the role (the coding
assistant in Ycode), "be concise; use Markdown", "you cannot edit files",
and the proposal format of §5.3. For agent tools and other single-prompt
back ends, the instructions, the earlier turns (as `<user>` /
`<assistant>` sections) and the new message are joined into one prompt.

### 5.2 Context and the token budget

The budget is the smaller of the model's context window (when known) and
Settings ▸ Context limit (default 32,768 tokens). From it, a reserve is
kept for the answer (a quarter of the budget, at least 256 and at most
4,096 tokens). Tokens are estimated as UTF-8 bytes / 4, rounded up. Then,
in this order, while they fit:

1. the instructions and the new message (always; a message too long for
   the budget alone is cut, with a note);
2. the workspace's name;
3. the attachments;
4. the selection (file, lines and text), unless attached;
5. the current file, whole; if it does not fit, the largest window of
   whole lines around the selection or caret that fits two thirds of
   what is left (labelled "Part of the current file …, lines a–b");
6. earlier messages of the conversation, newest first (once one does not
   fit, it and all older ones are left out);
7. the issues (errors first, at most 50, "- severity path:line: message");
8. the other open files, whole, each if it fits.

Items 5, 7 and 8 can be turned off in Settings. The context goes before
the message in a `<context>` section; files are fenced with their language.
What was left out is listed in the response's activity ("Left out to fit
the context: …"). Ollama gets the budget as `num_ctx`.

### 5.3 Proposals

A response proposes a change with a fenced code block whose info string
says what it is:

| Info string | Meaning |
|---|---|
| `<lang> file=<workspace-relative path>` (or `path=`) | the file's complete new contents (or a new file) |
| `<lang> selection` | replaces the selection the request was made from |
| `<lang> append` | adds the code at the end of the request's current file |

Other code blocks are examples. Unterminated blocks (still streaming) are
never proposals. Paths that are absolute or contain `..` are ignored; a
path that resolves outside the workspace folder is refused when reviewed.

**Review.** Review… opens a sheet titled "Change <file>: +a −r lines" (or
"Create <path>"), with the comparison view of `comparison.md`: the file's
current text on the left ("<file> (Current)", the open editor's text with
unsaved edits, or the file on disk), the text with the change on the right
("<file> (Proposed)"), both read-only. Buttons: Reject (Esc) and Accept
(Return), "Create File" for a new file.

- A selection proposal applies where the selection was when the request was
  made, if that text is still there; otherwise at the selection text's only
  occurrence; otherwise the review is refused ("The selected code changed
  since the request").
- **Accept** applies the change to the file's editor (opening the file
  first) as one undoable edit named "Apply Coding Assistant Change"; the
  document is left unsaved, so the user saves it or undoes it. For a new
  file, Accept creates it on disk and opens it (adding it to an
  `.xcodeproj` target is left to the user).
- **Reject** changes nothing. Either way, the block is marked "Applied" or
  "Rejected" in the transcript and the mark is saved.

## 6. Settings ▸ Coding Assistant

Sections and rows, in order:

- **Model Provider.** Use: Ollama | llama.cpp | OpenAI | Claude Code | Codex
  | Antigravity | ACP Agent. (The model is chosen in the pane.)
- **Local Models.** Ollama address; llama.cpp address; llama.cpp API key
  (Save / Remove).
- **OpenAI.** Sign-in method: Sign in with ChatGPT | API key. With ChatGPT:
  Account (status, "Continue with ChatGPT" or "Sign Out", the last
  message) and a note on plan usage, registration and the keychain. With
  an API key: API key (Save / Remove). Then OpenAI address.
- **Agent Tools.** For each tool: where it was found ("Found: <path>" or
  "Not found"), a path that replaces the search, and a model name (empty:
  the tool's default).
- **ACP Agent.** Command (the agent's executable and the arguments of its
  ACP mode) and where it was found (§10.5).
- **Agent Mode.** "Let agents use Ycode's tools and change files" (on by
  default), a note, the `ycode mcp` command line and the `claude mcp add`
  / `codex mcp add` lines with Copy buttons, and Ycode skill: Install in
  Workspace… (§10.6).
- **Context.** Context limit (tokens) (at least 1,024); Send the current
  file; Send the other open files; Send the workspace's issues (all on by
  default).
- **Output.** Most output tokens (default 4,096; empty: no limit),
  Temperature, Top P, Top K, Repeat penalty (empty: the server's default;
  §3.5).
- **Privacy.** "What is sent: your message, the attached file or selection,
  and, as allowed above, the current file (or the part of it that fits),
  the other open files and the issue list, plus the earlier messages of
  the conversation. With Ollama or llama.cpp this stays on the address you
  set (this Mac by default). With OpenAI it goes to OpenAI. With an agent
  tool it goes to that tool, which may also read files in the workspace
  folder and sends what it reads to its own service. Conversations are
  saved in Ycode's folder in Application Support, not in the workspace.
  Changes are only applied when you accept them."

Non-secret values are stored as one JSON value under the user default
`Ycode.codingAssistant`; changing addresses, the sign-in method or tool
paths makes open windows check the back ends again.

## 7. Secrets

- **macOS:** the login keychain, generic-password items with service
  "Ycode Coding Assistant" and accounts `openai.api-key`,
  `openai.chatgpt-tokens` (JSON: client ID, subject, email, access,
  refresh and ID tokens, type, expiry, scopes, time saved),
  `openai.chatgpt-registration` (host ID, issued client ID, subject,
  email; kept after sign-out) and `llamacpp.api-key`; accessible after
  first unlock, this device only.
- **Linux:** one file per account in `$XDG_CONFIG_HOME/ycode/secrets` (or
  `~/.config/ycode/secrets`), directory 0700, files created 0600 before
  anything is written and renamed into place.
- Never in user defaults, logs, conversations, the workspace or test
  fixtures. The settings pane never shows a stored value ("Saved in the
  keychain"). Tokens are never put in URLs; the authorization URL is not
  logged. Test processes use an in-memory store.

## 8. Tests

`YcodeAssistantTests` (macOS and Linux): providers against stand-in HTTP
servers on 127.0.0.1 (Ollama NDJSON, llama-server SSE with `[DONE]`,
Responses SSE; errors, unreachable servers, truncated streams, cancellation
closing the connection); the whole ChatGPT sign-in against a stand-in
issuer (discovery, JWKS, token and revocation endpoints; a simulated
browser calling the loopback redirect; PKCE checked by the stand-in; RS256
ID tokens on macOS; registration, re-sign-in with the issued client ID,
refresh rotation, unusable refresh tokens, revocation; declined, forged and
timed-out callbacks; a grant without plan usage); the agent tools against
stand-in executables printing the documented events (arguments, standard
input, working directory, error results, sign-in failures, interrupting a
running tool); the tool search; prompt budgeting; proposal parsing and
application; conversation archives; the file secret store's permissions;
the keychain (opt-in, `YCODE_KEYCHAIN_TESTS=1`). Opt-in live checks against
the developer's own back ends: `YCODE_LIVE_ASSISTANT=ollama,claude,codex,agy`.

`YcodeUITests` (`CodingAssistantUITests`, `CodingAssistantPaneR44Tests`
for the layout of `reference-ui-6.md` §9): ⌘0 and the pane, back-end
states and the empty state, sending with the editor's context and
streaming, Stop and Jump to Next Active Conversation, menu enablement, the
Document tool's proposal reviewed, rejected, accepted (undoable, file on
disk untouched), a new-file proposal, a path outside the workspace, and
the settings pane keeping keys out of user defaults.

## 9. Deviations that remain

- The selected conversation's transcript lives in the left area under
  the conversation list; the reference shows it in the editor area. (File
  ▸ New ▸ Conversation in New Tab / in Editor Pane do show one in the
  editor area.)
- The conversation list is per workspace; the reference's is per user
  (`reference-ui-6.md` §9.1 item 3).
- Show Coding Tools… ⌥⌘0 shows the code actions at the caret, not a coding
  tools popover with a prompt field; the four tools are in the menu.
- No history slider or automatic application of changes; no `@` references or symbol search in the
  message field (attachments instead); no "Generate Fix for Issue" button
  on issues; no reasoning-level pop-up. (Model Context Protocol tools and
  Agent Client Protocol agents: §10.)
- Agent tools build, test and run through Ycode's tools in agent mode
  (§10) and change files only through proposals; with agent mode off they
  run read-only and propose, as in §3.4.
- Behaviors ▸ Intelligence keeps the reference's category name and has no
  events.

## 10. Ycode implementation: agent mode, the Ycode MCP server, ACP

Xcode 27's public release notes describe agents that build, test, run and
render previews through Xcode's MCP server, agents hosted in the IDE over
the Agent Client Protocol, and skills (level 1). Ycode provides the same
capabilities with its own design: the tool names, schemas and behaviour
below are Ycode's, made from the public descriptions and the two public
protocol specifications. They do not follow the reference's private tool
list (open question for a dirty-room pass, only if interop ever needs it).

### 10.1 Protocols and transports

- **MCP** (modelcontextprotocol.io, MIT): revision **2026-07-28** served
  statelessly (every request names its version in
  `_meta["io.modelcontextprotocol/protocolVersion"]` with
  `clientCapabilities`; results carry `resultType: "complete"` and
  `_meta["io.modelcontextprotocol/serverInfo"]`; `server/discover`), and
  the initialize-based revisions **2025-11-25, 2025-06-18, 2025-03-26** for
  older clients (dual-era server: an `initialize` selects legacy behaviour
  for the stdio process or the HTTP client). Unknown versions: `-32022`
  with `data.supported`/`requested`; a modern request without client
  capabilities: `-32602`. Methods: `initialize`, `ping`, `server/discover`,
  `tools/list`, `tools/call`, `resources/list`, `resources/templates/list`,
  `resources/read`, `prompts/list`, `prompts/get`, `logging/setLevel`;
  notifications in: `notifications/initialized`, `notifications/cancelled`
  (stdio: cancels the request, no reply); out: `notifications/progress`
  for a request with `_meta.progressToken`. Batches are refused.
- **stdio** (`ycode mcp`): newline-delimited JSON-RPC on standard input and
  output; requests run concurrently. Standard output is kept for protocol
  messages only (it is duplicated at start and file descriptor 1 is pointed
  at standard error, so nothing a library prints can corrupt the stream).
  End of input ends the server and the programs it started.
- **Streamable HTTP** (`ycode mcp --http [port]`, and in the IDE): one
  endpoint `POST /mcp` on **127.0.0.1 only**; `Authorization: Bearer
  <token>` required (32 random bytes, hex; constant-time compare; else
  401 with `WWW-Authenticate: Bearer`); an `Origin` that is not loopback:
  403; GET and DELETE: 405 (no standalone stream, no sessions, no
  `Mcp-Session-Id`). Notifications and responses: 202. Modern requests
  must repeat `MCP-Protocol-Version`, `Mcp-Method` and, for `tools/call`,
  `prompts/get`, `resources/read`, `Mcp-Name` (the `=?base64?…?=` form is
  decoded) as headers; a mismatch is 400 with `-32020`; an unknown method
  404 with `-32601`; other protocol errors 400. Legacy errors come in 200
  responses. A request with a progress token that accepts
  `text/event-stream` gets an SSE stream (`event: message`, `X-Accel-
  Buffering: no`) of its progress notifications, then its response;
  otherwise one JSON object. `ycode mcp --http` takes the token from
  `YCODE_MCP_TOKEN` or prints a new one on standard error.
- **ACP** (agentclientprotocol.com, Apache-2.0), **protocol version 1**:
  Ycode is the client, the agent a subprocess speaking newline-delimited
  JSON-RPC on its standard input and output (§10.5).

### 10.2 The tools

Every tool has a JSON Schema 2020-12 input schema (`type: object`,
`additionalProperties: false`, a description on every property), most an
output schema; results carry `structuredContent` and the same data as text
(a summary first where it helps). Arguments are checked against the schema
(required keys, top-level types, unknown keys); failures, like every tool
failure, are results with `isError: true` and a message the model can act
on; an unknown tool name is `-32602`. Annotations: `readOnlyHint` true for
the reading tools; the write tools are `destructiveHint`. Paths are
relative to the workspace folder (a package's folder, or the folder that
holds the project or workspace); absolute paths must lie inside it, and
anything that leaves it (after resolving symbolic links) is refused. Each
tool takes an optional `workspace` (a path; opened when it is not the open
one), so a stateless client can name its workspace on every call.

| Tool | What it does |
|---|---|
| `workspace_open` | Opens a package (folder or `Package.swift`), `.xcodeproj` or `.xcworkspace` (a folder: the package in it, or its only workspace or project); describes it. |
| `workspace_describe` | Name, kind, path, folder, schemes, targets (with product types; a package's target folders), configurations, destinations (the host's, and each Ycode Simulator target when one is set up), selected scheme and destination, test plans, whether a simulator host is set up. |
| `file_list` | The workspace's files as Find in Workspace sees them (navigator order), relative; `glob` (fnmatch; a pattern without `/` also matches file names), `limit` (500). |
| `file_read` | Text with line numbers (`cat -n` style), `startLine`, `lineCount` (at most 2,000; "… more lines" says where to go on); the structured result has the plain text. The IDE's unsaved editor text wins over disk. Folders, files over 8 MB and non-UTF-8 files are refused. |
| `search` | Find in Workspace (`FindEngine`): text or `regex`, `ignoreCase` (default true), `wholeWord`, `limit` (200); `path:line:column: text` lines. |
| `issues` | The session's displayed issues (build, test and project issues) with relative path, line, column, notes and fix-its; counts. |
| `build_settings` | A project target's resolved settings for a configuration (default: the project's default configuration), optionally only `names`; packages: refused with a pointer to `Package.swift`. |
| `symbol_search` | Declarations in the workspace's Swift files whose name contains the query, with kind, line, declaration and the `///` or `/** */` comment above. Documentation of Apple's SDKs is not searched (the core has no documentation index; a DocC archive reader would add it). |
| `build`, `clean` | The session's Product ▸ Build / Clean Build Folder for `scheme` and `destination` (by name, id or specifier), documents saved first in the IDE. Every issue is collected (`stopOnFirstError` off in `ycode mcp`). Progress: the activity view's texts as `notifications/progress` (`done/total` when the text has counts). Result: status, counts, up to 300 issues, seconds, the last 30 log lines. |
| `test` | Product ▸ Test: all tests, `tests` (identifiers `Suite/name`, `Target/Suite/name`, or a bare name, matched against the tests found in the sources; unknown ones are refused with the known list), or a scheme's `plan`. Result: status, passed/failed/skipped, each outcome with its failures, the issues, the log tail. |
| `build_log` | The last build's or test run's log (`tail`, 200). |
| `run` | Builds, then runs the scheme's product: on this computer as a subprocess in the workspace folder with `arguments`, its output captured (`waitSeconds`, default 5, then the state and output so far); on a Ycode Simulator destination, the app bundle around the executable is installed and launched on the remote device (`WorkspaceSession.runOnRemoteSimulator`, no debugger in `ycode mcp`). A run ID for `run_output` and `stop`. |
| `run_output`, `stop` | A run's state and latest output (`tail`); stop: SIGINT, then SIGTERM after 3 s; a simulator run is stopped as Product ▸ Stop does (the device is saved with warm boot). |
| `simulator_list` | The remote host's simulator targets (`RemoteSimulator.all`): name, id, runtime, device directory, running. |
| `simulator_boot`, `simulator_shutdown` | Device Hub's Start and Shut Down (`RemoteDeviceSessions`); the launcher's lines are kept for `simulator_logs`. |
| `simulator_launch_app` | Installs a built `.app` and launches it on a device (`runOnRemoteSimulator`), waiting up to `waitSeconds` (60) for "Running …". |
| `simulator_screenshot` | The running device's screen as an MCP image block (`image/png`): one ssh call runs the launcher's `--control screenshot <display> <file>` into `<data>/shots/`, prints the PNG and removes it (`RemoteSimulator.screenshot`); `display` active, LCD or LCD-1. |
| `simulator_logs` | The launcher's and the app's latest console lines. |
| `preview_list` | A Swift file's `#Preview` and `PreviewProvider` declarations (name, line, kind, traits). |
| `preview_render` | One `#Preview` rendered headlessly to a PNG image block through OpenViews (`PreviewRenderRunner`, the same path as `ycode preview --render`; the OpenViews package must be found: `YCODE_OPENVIEWS` or `frameworks/swiftui` above the workspace or the executable). |
| `strings_catalogs` | The workspace's `.xcstrings` files: source language, key count, each language's progress. |
| `strings_list` | A catalog's rows for a `language` (key, source, comment, translation, state, variations); `missingOnly`: new, needs review, stale, or empty. A new language code lists every key. |
| `strings_set` (write) | One translation (state translated) through the String Catalog model; the language column is added when new. |
| `file_write` (write) | Creates a file or replaces its contents. |
| `file_edit` (write) | Replaces `oldText` (exact, occurring once unless `replaceAll`) with `newText`; missing or ambiguous text is explained. |
| `complete` | One predictive code completion at a 1-based line and column, from the backend in Ycode's settings (`specs/ide/predictive-completion.md` §7; added by PREDICT). |

Resources: every workspace file as a `file://` URI (at most 2,000, text
read like `file_read`), `ycode://workspace/build-log`, and
`ycode://workspace/issues` (JSON); the template `file:///{path}`. Reading
outside the workspace: `-32602`; an unknown URI: `-32602` (modern) or
`-32002` (legacy). Prompts: `build_and_fix` (`scheme`) and `run_tests`
(`tests`). The server's instructions describe the build–issues–edit loop
and the write rules.

### 10.3 Write mode and the security model

- **Read-only by default.** `ycode mcp` refuses the three write tools with
  a message naming `--allow-writes` and agent mode; `--allow-writes` lets
  them write directly.
- **Review** (the IDE): a write tool computes the change (the file's text
  before, from the editor when it is open, and after) and asks the write
  policy; the IDE shows it as a proposal (§10.4) and the tool answers only
  after the user decides: accepted → written (the IDE already saved it; the
  tool writes only if the disk differs), rejected → `isError` "The change
  was rejected in Ycode's review; nothing was written." Nothing is written
  before the decision.
- **Loopback and tokens.** HTTP listens on 127.0.0.1 only; the IDE starts
  one endpoint per agent request with a new token and stops it when the
  response ends. Claude Code gets the token in a 0600 file in a 0700
  folder (`--mcp-config`), removed after the run; Codex in its
  environment (`YCODE_MCP_TOKEN`, named by `bearer_token_env_var`). Tokens
  are never on a command line, in logs or in conversations.
- **Paths** are confined to the workspace folder (§10.2). The simulator
  tools use ssh with keys only (`BatchMode=yes`), as the IDE does.

### 10.4 Agent mode in the IDE

- **Settings.** Settings ▸ Coding Assistant ▸ Agent Mode (on by default).
  With it on, each request to Claude Code, Codex or the ACP agent gets an
  attachment: the window's MCP tools (one `YcodeMCPHost` over the window's
  own `WorkspaceSession`, so an agent's build shows in the activity view,
  the issue navigator and the report navigator), a new per-request server
  over those tools whose write policy is the conversation's review, and
  its loopback endpoint. The instructions become the agent instructions
  (use Ycode's tools; change files only through them; every change is a
  proposal; build after changing code). The response's activity says
  "Agent mode: Ycode's tools are attached; each change is a proposal you
  review".
- **Claude Code**: `-p --output-format stream-json --verbose
  --include-partial-messages --permission-mode default --tools
  Read,Grep,Glob --mcp-config <file> --strict-mcp-config --allowedTools
  mcp__ycode --restricted --no-session-persistence --permission-prompts
  none [--model M]`. `--safe-mode` (§3.4) would disable MCP servers, so
  agent mode uses `--restricted` (no command-running tools or WebFetch,
  the user's and project's settings files ignored, file tools confined to
  the working directory). Its own edit tools stay off; only Ycode's tools
  change files.
- **Codex**: the §3.4 command line plus `-c
  mcp_servers.ycode.url="<endpoint>"` and `-c
  mcp_servers.ycode.bearer_token_env_var="YCODE_MCP_TOKEN"`; the read-only
  sandbox stays (Ycode's tools run in Ycode). `mcp_tool_call` items show
  as activity ("ycode: build"); Claude Code's `mcp__ycode__build` tool uses
  likewise.
- **Antigravity**: no attachment (its print mode documents no MCP
  configuration); it stays read-only.
- **Proposals.** An agent's change is appended to the running response as
  a `<lang> file=<relative path>` block (a still-open fence is closed
  first; `~~~~` when the text holds backticks); paths outside the
  workspace or with spaces are refused. Review… shows the agent's exact
  text (not re-applied through §5.3); Accept applies it to the editor as
  one undoable edit and **saves** the file, since the agent builds from
  disk next; Reject changes nothing. The waiting tool call then returns.
  A response that ends with changes still waiting answers them as not
  accepted. After a tool writes, an open editor without unsaved edits is
  updated from disk.
- **Saving before builds.** The agent's `build`, `test` and `run` save
  the window's edited documents and projects first.
- **Off**: agents run as in §3.4 (read-only, proposals in text).

### 10.5 ACP agents

`ProviderKind.acpAgent` ("ACP Agent"): the command typed in Settings is
split like a shell (quotes group), its first word found like the agent
tools (§3.4). Not set or not found: "not installed" with the setup hint.
One agent process and one session per request (nothing is kept, like the
agent tools):

1. `initialize` `{protocolVersion: 1, clientCapabilities: {fs:
   {readTextFile: true, writeTextFile: true}, terminal: false},
   clientInfo: {name: "ycode", title: "Ycode", version}}`; another
   protocol version is an error.
2. `session/new` `{cwd: <workspace folder>, mcpServers}`: Ycode's endpoint
   as `{type: "http", name: "ycode", url, headers: [{name:
   "Authorization", value: "Bearer <token>"}]}` when the agent's
   `agentCapabilities.mcpCapabilities.http` is true, else none.
3. `session/prompt` with one text block (the flattened prompt, §5.1).
   `session/update` notifications for the session become the transcript:
   `agent_message_chunk` → text; `agent_thought_chunk` → "Thinking: …"
   activity per paragraph (or 240 characters); `tool_call` /
   `tool_call_update` → "<title> (<first location>)" with "…" (in
   progress), "✓" (completed) or "✗" (failed); `plan` → "Plan: ☑ done; ▸
   in progress; ☐ pending"; `current_mode_update` → "Mode: …"; `notice` →
   its title and description. The response's `stopReason` ends the turn:
   `cancelled` → "Stopped.", `refusal` → an error, others finish.
   Ending the stream (Stop) sends `session/cancel`; the agent process is
   interrupted when the request ends.
4. Agent requests: `fs/read_text_file` (absolute path inside the
   workspace, `line`/`limit` applied; the editor's text when open);
   `fs/write_text_file` → a proposal (§10.4); accepted → `{}`, rejected →
   error `-32003` "The change to <file> was not accepted in Ycode's review;
   nothing was written."; `session/request_permission` → a sheet with the
   agent's options as buttons (at most four; closing it is `{outcome:
   "cancelled"}`, a choice `{outcome: "selected", optionId}`); other
   methods (terminals) → method not found. Without agent mode the agent
   may read inside the workspace only; writes are refused and permission
   requests answered with the first reject option.

### 10.6 The Ycode skill

Only on the user's action (Settings ▸ Coding Assistant ▸ Ycode skill:
Install in Workspace…, after a confirmation naming the files; or `ycode
mcp install-skill [<folder>]`), Ycode writes the same Markdown file to
`.claude/skills/ycode/SKILL.md` (Claude Code's project skills) and
`.agents/skills/ycode/SKILL.md` (for other agents that read skills
there): YAML front matter (`name: ycode`, a `description` of when to use
it), the workflow (describe → read/search → edit → build → issues → test →
run → screenshot → preview), the write rules, and one line per tool,
generated from the tool list.

### 10.7 What is not done

- Plug-ins (the reference's agent plug-ins), a plan view (plans show as
  activity lines), session history across requests (`session/load`), ACP
  terminals, MCP `subscriptions/listen` and list-changed notifications
  (the tool list is fixed), elicitation and sampling (MRTR).
- `ycode-ide` (the Linux shell) does not attach the MCP server to agents
  (agent mode is the macOS IDE's); its agents run read-only and propose
  (§11). On Linux an agent the user runs gets Ycode's tools with
  `ycode mcp`.
- No Generate Translations command in the String Catalog editor (agents
  translate through `strings_list` / `strings_set`).
- Tests on the Ycode Simulator (`test` with a simulator destination) go
  through the session's runner as Product ▸ Test does; the remote tests
  were not run by this round.

### 10.8 Tests

`YcodeMCPTests` (macOS and Linux): JSON values and JSON-RPC framing
(lines split across reads, CRLF, batches refused, ids), peers (concurrent
requests, errors, cancellation without a reply, closing fails waiters);
the server (legacy `initialize` negotiation, modern `_meta` requests with
`resultType`, `-32022`, `-32602`, argument checks, write policies, prompts,
resource errors by era); every tool's schema; the HTTP transport (401,
403, 405, 202, header checks and `-32020`, base64 `Mcp-Name`, 404 and
`-32601`, `-32022`, SSE progress); each tool against
`Samples/AgentSamples/Greeter` (a copy) and `Samples/PackageSamples`
(build settings): open/describe/list/read/search/symbols, build with an
error → issues → `file_edit` → build → test (all, one, unknown) → run →
clean, write gating and review, String Catalogs, previews, resources, and
the simulator tools against a stand-in `ssh` that returns a PNG; an
end-to-end run of the built `ycode mcp` driven as a client (initialize,
build with progress, issue, read, edit, build green, tests green) and a
modern stateless client against a read-only server. `YcodeAssistantTests`
(`AgentModeTests`): an ACP session with an in-process stand-in agent
(updates, plan, tool calls, file read, permission, write through the
client; a rejected write; read-only handlers), event mapping, the ACP
provider with a shell-script agent process, agent-mode command lines for
Claude Code (config file mode 0600, removed afterwards, no token on the
command line) and Codex (token in the environment). `YcodeUITests`
(`AgentModeUITests`): an agent that calls the window's endpoint over HTTP
gets its `file_edit` as a proposal, accepted (saved, the tool answers
"Edited …") or rejected (nothing written), its permission request
answered; agent mode off; the skill; the window's host over its session.
Opt-in: `YCODE_MCP_THOR=1` with `YCODE_MCP_SIM_*` set runs
`simulator_boot`, waits for the launcher's "home screen at" line and
takes `simulator_screenshot` on the real remote host
(`YCODE_MCP_THOR_WAIT`: seconds to wait for a picture, default 600; a
shared host's launcher may first wait for a boot slot). The device
directory is the target's (`<device>-<type>-<runtime>`, run.md §Runtimes
and device types), so a copied device goes there.

### 10.9 Evidence

| Claim | Level | Source |
|---|---|---|
| Agents build, test, run and render previews through an MCP server; ACP agents in the IDE; skills | 1 | Apple, "Xcode 27 Release Notes" (developer.apple.com) |
| MCP 2026-07-28: per-request `_meta` keys, `server/discover`, `resultType`, error codes `-32020`/`-32021`/`-32022`, Streamable HTTP without sessions or GET, header mirroring and validation, base64 header values, SSE responses, `X-Accel-Buffering`, Origin checks, loopback binding, dual-era compatibility | 1 | modelcontextprotocol.io/specification/2026-07-28: versioning, basic (overview), server/discover, transports/streamable-http (read 2026-10-31) |
| Legacy `initialize`, tools, resources, prompts, progress, cancellation, content blocks, tool annotations, output schemas | 1 | modelcontextprotocol.io/specification/2025-11-25 and 2025-06-18 |
| ACP methods, `session/update` kinds and fields, `ToolCall`, `PlanEntry`, `PermissionOption`, outcomes, `McpServer` (stdio, http, sse), `StopReason`, `ProtocolVersion` (uint16; version 1) | 1 | agentclientprotocol.com: protocol overview and schema (read 2026-10-31) |
| Claude Code: `--mcp-config`, `--strict-mcp-config`, `--allowedTools mcp__<server>`, `--restricted`, `--safe-mode` disabling MCP servers; HTTP MCP config with headers | 1, 3 | `claude --help` (2.1.316); a read-only smoke run against `ycode mcp --http` on a copy of the Greeter sample: the server connected, `workspace_describe` and `build` were called (2026-10-31) |
| Codex: `-c mcp_servers.<name>.url`, `bearer_token_env_var`, `mcp_tool_call` items | 1, 3 | Codex configuration documentation; a read-only smoke run with `codex exec` 0.163.0 against `ycode mcp --http` (`workspace_describe` called; 2026-10-31) |
| Claude Code project skills in `.claude/skills/<name>/SKILL.md` with `name`/`description` front matter | 1 | Claude Code documentation, "Agent Skills" |
| `simulator_boot` → launcher "home screen at …" → `simulator_screenshot` returns the device's home screen (iPhone 18 Pro, iOS 27.0, cold boot, 95.5 s) | 3 | `MCPThorTests` against the arm64 Linux simulator host, 2026-10-31 |
| No ACP-capable agent CLI was installed on the Mac (Claude Code 2.1.316, Codex 0.163.0 and Antigravity offer MCP, not ACP); the ACP client is tested with stand-ins only | 3 | `--help` of each, 2026-10-31 |
| Everything else in §10 (tool names, schemas, results, the review flow, the skill text) | — | Ycode's design |


## 11. The Linux IDE (Ycode implementation, issue #18)

`ycode-ide` shows the same pane over the same `CodingAssistantModel`
(conversations, back ends, prompts, streaming, saving), through
`ShellAssistantModel`, which has no toolkit types and is tested headless:

- **Where it lives.** The navigator column's Navigators | Coding Assistant
  control (clicking the shown one hides the area), View ▸ Navigators ▸
  Show Coding Assistant (Ctrl+0; "Hide Coding Assistant" while shown),
  File ▸ New ▸ Conversation, Navigate ▸ Jump to Next Active Conversation,
  Editor ▸ Show Coding Tools ▸ Explain / Document / Generate a Playground
  / Generate a Preview, and the toolbar's New Conversation prompt (a
  pop-up under the button; sending starts a conversation in the pane).
  Choosing a navigator leaves the pane.
- **Layout.** As §4: the header (New Conversation with its provider
  chevron, New Group), the list (groups, conversations, Archive last; a
  context menu renames, files, archives and deletes; double-click renames),
  the status note, the transcript, then the message field. Above the field
  a line says what the request carries ("Sends: Greeting.swift · lines 3–4
  selected · 2 issues · 1 other open file", following the Context
  settings); attachment chips; under it the attach menu (Current File,
  Selection), the "Provider · Model" pull-down and Send / Stop.
- **Proposals in the transcript.** Each proposal (§5.3) is a card with its
  title, "+a −r" and the change as a compact diff (old or new line number,
  a bar beside added and removed lines on a tinted band, at most 40 lines;
  Review… shows all), and Review…, Reject and Accept ("Create File" for a
  new file; Accept is off when the proposal changes nothing). A response
  with more than one undecided proposal also offers Accept All and Reject
  All. Review… opens the side-by-side sheet of §5.3 (Reject on Esc,
  Accept on Return). A decided card keeps the diff it was decided on,
  dimmed, with "Applied" or "Rejected".
- **Accept** applies the change in the file's editor (opened first) as one
  undo step that replaces only the part that differs, left unsaved; a new
  file is created and opened. The change applies only to the text it was
  shown against: if the editor's text changed since, nothing is applied
  and the pane says so. Nothing is written to disk until the user saves.
- **Context** (§5.2) comes from the editor: the file's text with unsaved
  edits, the caret line, the selection (lines and UTF-16 range), the other
  open files, and the Issue navigator's issues.
- **Settings ▸ Coding Assistant** has the sections of §6. Addresses and
  paths apply on Return. Keys go to `FileSecretStore` (§7:
  `$XDG_CONFIG_HOME/ycode/secrets`, 0700 folder, 0600 files); the field
  shows only that a key is saved.
- **Storage.** Conversations are saved in
  `$XDG_DATA_HOME/Ycode/Conversations/<hash>.json` (Foundation's
  Application Support folder on Linux).
- **Not in the Linux IDE.** Agent mode's MCP attachment (agents run as in
  §3.4); conversations in editor tabs or panes (Conversation in New Tab /
  in Editor Pane); ⇧Return for a new line in the message field (OpenViews'
  vertical text field sends on Return); dragging conversations between
  groups (the context menu files them).
- **Tests.** `ShellAssistantTests` (macOS and Linux): a stand-in
  OpenAI-compatible server on 127.0.0.1 and a stand-in Claude Code script
  printing its stream-json events; asking with the editor's context,
  streaming, two proposals as diffs, accepting one and rejecting the other
  (the disk untouched until Save All), Accept All and Reject All, review,
  refusals, the commands and the list. The end-to-end walk
  (`YCODE_IDE_ASSISTANT=<prefix>`, `ShellDriver+Assistant.swift`) does the
  same in the running IDE with the pointer and keyboard against a stand-in
  server it starts, saves a stand-in key through Settings, and checks the
  files on disk, the key file's mode and that the request carried the key.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Menu items, shortcuts, toolbar control and New Conversation button | 3 | `reference-ui-5.md` §2, §4 |
| Conversation list, transcript, Stop, attachments, renaming by first prompt, proposals applied by the user, settings for providers, `/v1/models` + `/v1/chat/completions` for added providers, local providers by address | 1 | Apple, "Setting up coding intelligence", "Writing code with intelligence in Xcode" |
| Explain / Document / playground / preview behavior | 1 | Apple, "Using coding intelligence in the source editor" |
| Ollama API (`/api/tags`, `/api/show`, `/api/chat`, NDJSON, `num_ctx`) | 1 | Ollama API documentation |
| llama-server endpoints, default port 9931, `--api-key`, `/props` | 1 | llama.cpp `tools/server/README.md` |
| Chat Completions streaming (`choices[].delta`, `[DONE]`) | 1 | OpenAI API reference |
| Sign in with ChatGPT for open-source apps: endpoints, parameters, scopes, `dynamic_agent_client`, host IDs, loopback redirect, token, refresh and revocation rules, ID-token checks, scope check, error codes, UI wording ("Continue with ChatGPT", "You're using your ChatGPT plan", "Manage usage") | 1 | developers.openai.com/siwc: overview, sign-in, accounts and sessions, models and inference, token reference, errors and recovery, preview limitations, UI/UX guidelines (read 2026-10-27) |
| Responses API fields and events | 1 | the same pages; OpenAI API reference |
| PKCE S256, loopback redirect, OAuth form encoding, revocation | 1 | RFC 7636, RFC 8252 §7.3, RFC 6749, RFC 7009 |
| ID token accepted over TLS without a signature check (Linux) | 1 | OpenID Connect Core 1.0 §3.1.3.7 step 6 |
| Claude Code headless flags and stream-json events | 1 | Claude Code documentation: "Run Claude Code programmatically", CLI reference |
| Codex `exec --json` events, sandbox modes, flags | 1 | Codex documentation: non-interactive mode; `codex exec --help` |
| Antigravity CLI print mode, stream-json events, `--mode plan`, `--sandbox` | 1 | Antigravity CLI documentation: headless mode, CLI reference; `agy --help` |
| Each tool's real output matches the parsers | 3 | one read-only smoke prompt per installed tool (Claude Code 2.1.311 with no tools, Codex 0.163.0, Antigravity CLI 1.4.3) and one against Ollama 0.40.11 with qwen2.5-coder, 2026-10-27 |
| The Linux IDE's pane (§11): the same placement and commands as §4, inline diffs with Accept / Reject / Accept All / Reject All, the context line | — | Ycode's design, over the shared model and the §4 commands (level 3 for the commands, as above) |
| Everything else | — | Ycode's design |
