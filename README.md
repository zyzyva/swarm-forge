<p align="center" style="color: red; font-weight: bold; font-size: 2em; font-style: italic; text-decoration: underline;">
Do not spend any money on a bankrbot SWARM token.
</p>

# SwarmForge

**A disciplined tmux-based agent orchestration platform that turns swarms of AI agents into reliable, professional software engineers.**

## Intent

SwarmForge is an agent coordination system that facilitates communication between agents working in different git worktrees.

It provides a shared structure for role-specific prompts, worktree assignment, tmux sessions, and message passing so multiple agents can collaborate on the same project without stepping on each other.

## What SwarmForge Does

SwarmForge is a lightweight, tmux-based orchestration layer that:

- Launches a **config-driven swarm** from a project-local `swarmforge/swarmforge.conf`
- Creates one tmux session and one Terminal window per configured role
- Reads behavior from project-local `swarmforge/<role>.prompt` files plus a layered `swarmforge/constitution.prompt`
- Supports per-role backends such as `claude`, `codex`, `aider`, `copilot`, `grok`, or `none`
- Creates a project-local `swarmtools/` directory with notification helpers for the active swarm
- Creates one git worktree per configured role under `.worktrees/`
- Initializes a git repository in a new working directory and creates a first commit with `logs/` and `agent_context/` ignored
- Keeps all swarm state local to the working directory in `.swarmforge/`

## Core Features

- **Config-Driven Topology** — The swarm shape comes from `swarmforge/swarmforge.conf`, not hardcoded shell variables.
- **Project-Local Roles** — Each role is defined by `swarmforge/<role>.prompt` in the working tree being orchestrated.
- **Layered Constitution** — `swarmforge/constitution.prompt` can delegate to subordinate files such as `swarmforge/constitution/project.prompt`, `engineering.prompt`, and `workflow.prompt`.
- **Backend Selection Per Role** — A role can launch `claude`, `codex`, `aider`, `copilot`, `grok`, or no agent at all.
- **Observable Swarm** — Open one Terminal window per role and watch the sessions in real time.
- **Self-Hosted & Lightweight** — Runs locally in tmux and Terminal with minimal machinery.

## Constitution And Roles

In a configuration with an `architect`, `coder`, and `reviewer`, the recommended prompt layout is:

```text
swarmforge/
  swarmforge.conf
  constitution.prompt
  constitution/
    project.prompt
    engineering.prompt
    workflow.prompt
  architect.prompt
  coder.prompt
  reviewer.prompt
```

`constitution.prompt` is the entry point. It can define precedence and direct agents to read subordinate constitution files in order. That lets you separate project-specific rules from engineering rules and workflow rules without forcing everything into one large prompt.

The default three-agent workflow is:

- `architect` defines behavior, plans, and acceptance-level intent
- `coder` implements one small slice at a time and hands off completed work
- `reviewer` performs deeper verification and quality checks before final handoff

## How It Works (High Level)

1. Create a `swarmforge/` directory in the target working directory.
2. Put `swarmforge.conf`, `constitution.prompt`, and one `<role>.prompt` file per configured role inside it. If needed, add subordinate files under `swarmforge/constitution/`.
3. In `swarmforge/swarmforge.conf`, define each window as `window <role> <agent> <worktree>`.
4. Add `swarmforge.sh` to your shell `PATH` before startup.
5. Run `swarmforge.sh <working-directory>` or run it from inside that directory.
6. If the working directory is not already a git repo, startup runs `git init`, renames the initial branch to `master`, writes `.gitignore` entries for `.swarmforge/`, `.worktrees/`, `swarmtools/`, `logs/`, and `agent_context/`, and makes the first commit from the current project state.
7. Startup creates a git worktree for each window under `.worktrees/<worktree>`, unless the worktree field is `none` or `master`.
8. Startup creates `swarmtools/notify-agent.sh` for that project and installs the sequenced handoff helpers next to it.
9. SwarmForge creates tmux sessions, opens Terminal windows, and launches each configured backend in its assigned worktree.
10. Roles communicate through sequenced handoffs: `notify-agent.sh send` assigns message ids and sequence numbers, archives sent messages, records logbook entries, and delivers the message; `notify-agent.sh receive` validates ordering and requests resends when gaps are detected.

## The `swarmforge.conf` File

`swarmforge/swarmforge.conf` defines the swarm window-by-window. Each line has this form:

```conf
window <role> <agent> <worktree> [notify-target]
```

The optional `notify-target` field names another role to auto-notify when the sidecar detects a new commit in this role's worktree. This is primarily useful for `aider` backends that cannot call `notify-agent.sh` directly.

You can define as many windows as your project needs. Each `role` maps to a corresponding prompt file at `swarmforge/<role>.prompt`, so a config containing `architect`, `coder`, `reviewer`, `research`, and `release` windows would expect:

- `swarmforge/architect.prompt`
- `swarmforge/coder.prompt`
- `swarmforge/reviewer.prompt`
- `swarmforge/research.prompt`
- `swarmforge/release.prompt`

This lets each project choose its own swarm shape instead of being locked to a fixed set of roles.

The first window in the config is the cleanup window. SwarmForge attaches shutdown cleanup to that window's launch command and falls back to that tmux session when no trackable terminal backend is available.

When SwarmForge opens trackable terminal windows or tabs, it also starts a small window watchdog:

- Closing a non-cleanup terminal surface reopens that surface attached to the same tmux session.
- Closing the cleanup terminal surface shuts down all configured tmux sessions and closes the remaining tracked surfaces.
- The watchdog updates `.swarmforge/window-ids` when it reopens a window so shutdown cleanup still targets the current windows.

## Sequenced Handoffs

Agents communicate through sequenced handoff files so a dropped or garbled tmux message cannot silently stall the swarm.

To send a handoff, an agent writes the role-specific body to a file and runs:

```sh
./swarmtools/notify-agent.sh send <target-role> --file ./tmp/<target-role>-handoff.txt
```

The helper wraps the body with protocol fields before delivery:

```text
message type: handoff
message id: handoff-YYYYMMDD-HHMMSS-sender-target-NNNNNN-XXXXXX
sender role: sender
target role: target
message sequence: NNNNNN
```

Sequence numbers are per sender-target stream. Sent messages are archived in the sender's worktree under `.swarmforge/handoffs/sent/` so they can be replayed later, and every send, receive, and queued decision is appended to a `logbook.jsonl` file at the worktree root.

When an agent receives a handoff, it saves the complete incoming message to a file and runs:

```sh
./swarmtools/notify-agent.sh receive --file ./tmp/incoming-handoff.txt
```

If the sequence is exactly one greater than the last processed message from that sender, the helper records the message and reports `OK to process`. If there is a gap, the helper archives the out-of-order message, records a queued logbook entry, sends a `resend-request` to the sender for the missing range, and tells the agent not to process it. The sender's `receive` handles a `resend-request` by replaying the archived messages automatically.

Sender and receiver roles default from the `SWARMFORGE_ROLE` environment variable, which SwarmForge exports into every agent's launch environment; the helpers also accept explicit `--sender`/`--receiver` flags.

The low-level transport form remains available for plain messages that intentionally bypass sequencing (such as `/compact` nudges) and for the helper implementation itself:

```sh
./swarmtools/notify-agent.sh <target-role-or-index> --file <message-file>
```

## tmux Behavior

SwarmForge uses a project-specific tmux socket recorded in `.swarmforge/tmux-socket`, so each project swarm is isolated from other tmux sessions. It also honors tmux `base-index` and `pane-base-index` settings when launching agents and sending notifications, so configurations that number windows or panes from `1` work without requiring users to change their tmux preferences.

## Terminal Behavior

SwarmForge opens trackable terminal windows or tabs through a small terminal backend adapter.

Default detection:

- If AppleScript is available, SwarmForge opens macOS Terminal.app windows.
- Otherwise, if `wt.exe` is available, SwarmForge opens Windows Terminal windows.
- Otherwise, SwarmForge attaches the cleanup tmux session in the current shell.

Set `SWARMFORGE_TERMINAL` to override detection:

```sh
SWARMFORGE_TERMINAL=ghostty ./swarm
SWARMFORGE_TERMINAL=terminal-app ./swarm
SWARMFORGE_TERMINAL=windows-terminal ./swarm
SWARMFORGE_TERMINAL=none ./swarm
```

Use `ghostty` when you want SwarmForge to open Ghostty tabs instead of the default Terminal.app windows.
Use `windows-terminal` when you want SwarmForge to open Windows Terminal windows from WSL.
Use `none` when you want SwarmForge to skip terminal automation and attach the cleanup tmux session in the current shell.

### Adding A Terminal Backend

Terminal backends live in `terminal-adapters/`. To add a new backend, create one file named after the backend:

```text
terminal-adapters/wezterm.sh
```

The file must define this small contract:

```sh
terminal_backend_label() {
  echo "WezTerm"
}

terminal_backend_can_open_sessions() {
  return 0
}

terminal_backend_tracks_windows() {
  return 0
}

terminal_open_session() {
  local session="$1"
  local title="$2"
  local sibling_id="${3:-}"

  # Open a terminal surface that runs:
  # cd "$WORKING_DIR" && exec tmux -S "$TMUX_SOCKET" attach-session -t "$session"
  #
  # Print a stable window/tab id to stdout.
}

terminal_window_exists() {
  local window_id="$1"

  # Return 0 if the id from terminal_open_session still exists.
  # Return nonzero otherwise.
}

terminal_close_window() {
  local window_id="$1"

  # Close the id from terminal_open_session.
}
```

Then run SwarmForge with the backend name:

```sh
SWARMFORGE_TERMINAL=wezterm ./swarm
```

If the terminal can open sessions but cannot return stable ids for open/check/close, keep `terminal_backend_can_open_sessions` as `return 0` and set `terminal_backend_tracks_windows` to `return 1`. SwarmForge will open one surface per session and skip the watchdog for that backend. `terminal-adapters/windows-terminal.sh` is an example of this launch-only style.

If the backend cannot open sessions at all, set both capability functions to `return 1`; SwarmForge will attach the cleanup tmux session in the current shell. Only edit `swarm-terminal-adapter.sh` when adding aliases or changing default auto-detection.

Example config:

```conf
window coordinator codex master
window coder codex coder
window refactorer codex refactorer
window architect codex architect
```

In the example above, the agents run in these worktrees:

- `coordinator` -> main working directory on `master`, and is the cleanup window because it is listed first
- `coder` -> `.worktrees/coder`
- `refactorer` -> `.worktrees/refactorer`
- `architect` -> `.worktrees/architect`

If a window uses `master` as its worktree name, SwarmForge does not create `.worktrees/master`; that role runs in the main working directory on the `master` branch.

## Skills

Agents launched with the `claude` backend inherit every Claude Code skill installed for the current user (global `~/.claude/skills/` and any plugins). This means role prompts can instruct an agent to invoke specific skills at specific moments — for example, telling a coder to run the `simplify` skill before handoff, or telling a reviewer to run `pr-review-toolkit:code-reviewer`, `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:pr-test-analyzer`, and similar.

A few things to keep in mind:

- Skills are a Claude Code feature. Agents launched with the `codex` or `aider` backend do not have access to skills, and any skill instructions in their prompt will be ignored.
- Skill availability depends on what the user running SwarmForge has installed. If a prompt names a skill that is not installed, tell the agent to note it in its handoff rather than skip silently so drift is visible.
- Role prompts are the right place to wire skills in. Put skill invocation rules near the handoff step of the role that owns that quality gate (coder for pre-handoff cleanup, reviewer for verification).

See `examples/clojureHTW-pairs/swarmforge/coder.base.prompt` and `reviewer.base.prompt` for a worked example of skill usage in role prompts.

## Mixed-Model Swarms With The `aider` Backend

The `aider` backend lets you run open-source or third-party models alongside Claude in the same swarm. Aider supports any model provider that offers an OpenAI-compatible API (Fireworks, Together, OpenRouter, Groq, local Ollama, etc.) via LiteLLM.

A typical mixed-model config uses Claude Opus for planning and review, and a cheaper or open-source model for implementation. The optional 5th field specifies the auto-notify target — when the aider agent commits, the sidecar notifies that role automatically:

```conf
window architect claude master
window coder    aider  coder   reviewer
window reviewer claude reviewer
```

### Model Selection

Set the aider model per role using the same env vars as other backends:

```sh
export SWARMFORGE_CODER_MODEL="fireworks_ai/accounts/fireworks/models/kimi-k2-6"
export FIREWORKS_API_KEY="your-key"
```

Any model string that aider accepts works here. See [aider's model documentation](https://aider.chat/docs/llms.html) for the full list of supported providers and model name formats.

### API Keys

Aider reads API keys from environment variables matching the provider. Export the relevant key before running `swarm`:

| Provider | Environment Variable |
|---|---|
| Fireworks | `FIREWORKS_API_KEY` |
| Together | `TOGETHER_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| Groq | `GROQ_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Ollama | No key needed (local) |

### Extra Aider Flags

Pass additional aider CLI flags through `SWARMFORGE_AIDER_FLAGS`:

```sh
export SWARMFORGE_AIDER_FLAGS="--auto-commits --dark-mode"
```

### Prompt Delivery

Aider receives context differently from Claude Code and Codex. SwarmForge passes the constitution, role prompt, and instruction file as `--read` files so aider loads them into its context, and sends the instruction file content as the initial `--message`.

### Autonomous Operation And Safety

Aider does **not** execute arbitrary shell commands — it is a file editor and git client. The `--yes-always` flag (included automatically) auto-approves file edits only. This is closer to Claude Code's `auto` mode than `bypassPermissions`:

| Operation | Behavior |
|---|---|
| File edits | Auto-approved (isolated in worktree, auto-committed, fully reversible) |
| Git commits | Auto via `--auto-commits` (in worktree, not pushed) |
| Lint/test | Only through `--auto-lint` / `--auto-test` with a command you specify |
| Shell commands | Not executed by aider. Handled by the sidecar (see below). |

For test-driven autonomy, add `--auto-test` with your project's test command:

```sh
export SWARMFORGE_AIDER_FLAGS="--auto-test --test-cmd 'go test ./...'"
```

### The Aider Sidecar

Aider cannot run shell commands, call `notify-agent.sh`, or execute `git merge`. SwarmForge starts a **sidecar process** alongside every aider agent to bridge this gap. The sidecar handles three things:

**Commit watcher** — polls the worktree for new commits and sends a sequenced handoff (via `notify-agent.sh send`) to the role specified in the 5th config field. The architect and reviewer hear from the coder automatically, with sequence numbers and logbook entries like any other handoff.

**Merge handler** — when another agent calls `notify-agent.sh --merge <branch> coder "message"`, the script writes a merge operation to `.swarmforge/ops/<role>.queue`. The sidecar picks it up and executes `git merge` in the aider worktree. If the merge fails, it aborts and notifies aider of the conflict.

**Command runner** — aider can write shell commands to `.sidecar/commands` (one per line) since file editing is its core capability. The sidecar executes them and writes output to `.sidecar/results`. A **deny list** blocks destructive commands (`rm -rf`, `git push`, `git reset --hard`, `sudo`, pipe-to-shell, etc.).

The sidecar runs as a background process in the same tmux session and dies when the session is killed. Logs go to `logs/sidecar-<role>.log`.

### Handoffs With `--merge`

When an agent needs the aider coder to merge, use the `--merge` flag:

```bash
notify-agent.sh --merge swarmforge-architect coder "Review your rules. Merge from branch swarmforge-architect (abc1234). Here is what changed..."
```

For `claude` and `codex` targets, `--merge` is ignored (the agent handles merges itself). For `aider` targets, the merge is routed to the sidecar. The text message is still sent to aider for context either way.

Note that `--merge` uses the low-level transport form, which bypasses sequencing. That is acceptable for aider targets because aider reads message text directly and does not run receive-side validation.

### Adapting Prompts For Less Capable Models

Open-source models may need more explicit instructions than Claude. The generic example prompts include optional guidance sections for this:

- `examples/generic/swarmforge/architect.prompt` has an "Explicit Handoffs For Less Capable Coders" section — the architect names exact files, spells out the approach, and gives concrete examples instead of relying on the coder to infer intent.
- `examples/generic/swarmforge/reviewer.prompt` has a "Reviewing Work From Less Capable Coders" section — the reviewer gives exact fix instructions, checks for hallucinated APIs, and lists all issues in a single rejection instead of one at a time.

Copy these sections into your project's role prompts when using a less capable model for the coder.

### Limitations

- Skills are a Claude Code feature and are not available to the `aider` backend.
- Effort levels (`SWARMFORGE_EFFORT`, `SWARMFORGE_CODER_EFFORT`, etc.) are a Claude Code concept and do not apply to aider.
- Slash commands like `/compact` and `/clear` are Claude Code features. Use `/reset` in aider to clear its context instead.
- The sidecar command runner uses `eval` — the deny list blocks known-dangerous patterns but is not a sandbox. For high-security environments, run the swarm in a container.

## Mixed-Model Swarms With The `claude` Backend

The `claude` backend can also run non-Anthropic models, as long as the provider exposes an Anthropic-compatible API (for example MiniMax at `https://api.minimax.io/anthropic`). Route a single role at such an endpoint with per-role env vars:

```sh
export SWARMFORGE_CODER_BASE_URL="https://api.minimax.io/anthropic"
export SWARMFORGE_CODER_AUTH_TOKEN="your-provider-key"
export SWARMFORGE_CODER_MODEL="MiniMax-M3"
```

`SWARMFORGE_<ROLE>_BASE_URL` / `SWARMFORGE_<ROLE>_AUTH_TOKEN` follow the same naming as the model and effort vars: role uppercased, non-alphanumerics replaced with `_` (so `coder-2` reads `SWARMFORGE_CODER_2_BASE_URL`). `SWARMFORGE_BASE_URL` / `SWARMFORGE_AUTH_TOKEN` are shared fallbacks that route every claude-backend role at once. Roles with no override use the default Anthropic endpoint and your normal credentials.

Notes:

- Always pair a base-URL override with the matching `SWARMFORGE_<ROLE>_MODEL`; otherwise the role asks the provider for an Anthropic model name it likely doesn't serve.
- Effort levels are an Anthropic-only concept. Roles routed at a custom endpoint skip the `CLAUDE_CODE_EFFORT_LEVEL` export automatically.
- The auth token is written to a `600`-permission file under the git-excluded `.swarmforge/prompts/` directory and sourced at launch, so it never appears in the tmux pane or shell history.
- Only the `claude` backend reads these vars. The `aider` backend routes providers through its model string (see above).

### The Budget Implementer Fragment

A cost-optimized coder needs smaller, more prescriptive slices from the roles that define its work. If `swarmforge/budget-implementer.prompt` exists in your project, SwarmForge appends it to the specifier and architect instructions whenever:

- any coder role has a base-URL override (per-role or shared), or
- `SWARMFORGE_BUDGET_IMPLEMENTER=1` is set — use this to force it when the budget model is reached through the normal Anthropic endpoint (e.g. Haiku) or through the `aider` backend.

Projects without the fragment file are unaffected. See also "Adapting Prompts For Less Capable Models" above for the aider-flavored equivalent.

## The Optional QA Role

`swarmforge/qa.prompt` defines an opt-in QA gate: an agent that black-box tests the running product end to end — real user flows through the real interface, mobile viewports, accessibility, degraded networks, security probing — rather than reviewing source code (that remains the reviewer's job). It reproduces every failure deterministically, files defects to the architect or specifier through the file-based handoff format, and never edits production code.

Enable it by adding a window to `swarmforge/swarmforge.conf`:

```conf
window qa claude qa architect
```

QA runs at feature and pre-merge/pre-demo boundaries, not on every micro-slice. Tune it like any other role with `SWARMFORGE_QA_MODEL` and `SWARMFORGE_QA_EFFORT`.

## Examples

The repository includes example swarm definitions under `examples/`.

- `examples/generic/swarmforge/` is a stack-agnostic starter: a layered constitution with behavioral engineering rules adapted for parallel-worktree swarms, plus role prompts for architect/coder/reviewer that don't lock you into a specific test framework.
- `examples/clojureHTW/swarmforge/` shows a layered constitution and agent prompts for a Clojure Hunt The Wumpus project, including a queueing rule for messages that arrive while an agent is busy.
- `examples/clojureHTW-pairs/swarmforge/` extends the same project with two parallel coder/reviewer pairs (`coder-a`+`reviewer-a`, `coder-b`+`reviewer-b`) coordinated by a single architect. Use this layout when you want slices of work to run in parallel and the architect to serialize merges back to `master`.

Use these example directories as starting points for project-local `swarmforge/` folders.

## Getting Started

- In the directory where you want to use SwarmForge, pull the repository contents without creating a Git remote:

  ```sh
  curl -L https://github.com/unclebob/swarm-forge/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
  ```
	
## Running SwarmForge

Just type `swarm`. The windows should all pop up.

## Context Hygiene For Long-Running Swarms

Agents accumulate context across every slice. After dozens of slices, sessions can run hundreds of thousands of tokens deep — expensive per call, and a real risk for subtle drift (forgetting earlier rules, conflating patterns across slices, repeating corrected mistakes).

Two disciplines keep the swarm performant without losing useful continuity:

- **`/compact` between sub-slices.** After each slice merges and both agents are idle, send `/compact` via `notify-agent.sh`. The agent's harness summarizes verbose intermediate tool-call and test-output noise while preserving the high-signal context — constitution rules, established patterns, reviewer-flagged carry-forwards.
- **`/clear` at phase boundaries.** When a major plan phase closes, send `/clear` before the first slice of the next phase. The agent re-reads its role prompt and the constitution on its next prompt and bootstraps fresh.

Within a slice, do nothing — mid-slice continuity matters; let the agent finish.

If a `/compact` visibly drops important context (agent forgets a carry-forward, references a wrong pattern), escalate to `/clear` immediately.

Both are slash commands the agent harness interprets in its conversation buffer:

```bash
swarmtools/notify-agent.sh coder "/compact"
swarmtools/notify-agent.sh reviewer "/compact"
```

When a backend doesn't expose `/compact` / `/clear` as slash commands, the guidance applies in spirit; check your harness for equivalents.
