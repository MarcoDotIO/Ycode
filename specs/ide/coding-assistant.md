# Coding assistant

Ycode modules: `YcodeAssistant` (platform-neutral: providers, conversations,
prompt building, change proposals, secret storage, OpenAI sign-in; builds
and tests on Linux), `YcodeSubprocess` (`StreamingSubprocess`), `YcodeUI`
(`Assistant/CodingAssistantModel`, `CodingAssistantViewController`,
`ConversationView`, `NewConversationPrompt`, `ProposalReviewController`, `CodingAssistantServices`,
`WorkspaceWindowController+CodingAssistant`,
`App/CodingAssistantSettingsPane`).

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
  | Antigravity. (The model is chosen in the pane.)
- **Local Models.** Ollama address; llama.cpp address; llama.cpp API key
  (Save / Remove).
- **OpenAI.** Sign-in method: Sign in with ChatGPT | API key. With ChatGPT:
  Account (status, "Continue with ChatGPT" or "Sign Out", the last
  message) and a note on plan usage, registration and the keychain. With
  an API key: API key (Save / Remove). Then OpenAI address.
- **Agent Tools.** For each tool: where it was found ("Found: <path>" or
  "Not found"), a path that replaces the search, and a model name (empty:
  the tool's default).
- **Context.** Context limit (tokens) (at least 1,024); Send the current
  file; Send the other open files; Send the workspace's issues (all on by
  default).
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
  on issues; no reasoning-level pop-up; no Model Context Protocol tools;
  no Agent Client Protocol agents.
- Agent tools run read-only and propose; they do not build or edit the
  project themselves.
- Behaviors ▸ Intelligence keeps the reference's category name and has no
  events.

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
| Everything else | — | Ycode's design |
