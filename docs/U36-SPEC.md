# U36: Antigravity seats

Antigravity is not known to Agencil at all. It ships a terminal agent, `agy`, with a headless mode (`agy -p`, one
prompt, prints the answer, exits; `--print-timeout` default 5 min), stream-json output and an ACP mode
(antigravity.google/docs/cli/headless, /docs/cli/reference). Reported risks: a tool call that would prompt in an
interactive run stalls silently in headless mode, and `permissions.allow` in settings is only partly honoured there
(google-antigravity/antigravity-cli issue 548). On the owner's Mac the `~/.antigravity/antigravity/bin/agy` link
points at a path the installed app no longer has, so discovery must not trust that link.

Since 2026-11 Google refuses Gemini CLI with a personal login and points to Antigravity (docs/U35-SPEC.md
"Findings"), so this unit is the subscription route to Google models. Install: `brew install --cask antigravity-cli`
or Google's install script, which puts `agy` in `~/.local/bin`; the first run signs in through the browser.

## Step 0: spike, go or no-go (before any code is merged)

On a Mac with a working `agy` and a signed-in account, record in this file:
1. Where `agy` installs and what `agy --version` prints (for discovery and the probe).
2. Whether a read-only mode exists that refuses file writes, shell and web fetch **without** a prompt (a policy
   file, an agent with no such tools, or a flag). `--dangerously-skip-permissions` is never used by Agencil.
3. Whether MCP servers and extensions can be turned off for one run.
4. Where the login lives (file, Keychain item) and which variable moves its home, for a per-run home as in U34/U35.
5. The shape of `-o json` / stream-json, for the answer and usage.

**No-go** if item 2 has no answer: Antigravity then stays "found, not runnable" in onboarding with the reason shown,
and this unit ends with discovery only (items 1 and 2 of Behaviour). A seat whose tools can stall or write is not
shipped.

## Behaviour (on go)

1. **Kind.** `antigravity` joins `SeatConfig.harnesses` and the harness catalog (executable `agy`, vendor `google`).
2. **Discovery.** Candidates whose link does not resolve are reported as "install broken" with the dangling path,
   never as found.
3. **Adapter.** `[agy, "-p", prompt, "-m", model, <read-only switch from step 0>, <no-MCP switch>]`, plus the JSON
   output flag when `reportUsage`, and `--print-timeout` set to the seat's cap. Answer from stdout or the JSON.
4. **Policies.** Only what step 0 proved, as in U35 item 2.
5. **Per-run home, usage, preset, resolver** as U35 items 3 to 6, with the paths step 0 recorded. Antigravity data
   under `~/.gemini/antigravity` is never granted to a Gemini seat and vice versa.

## Threat model

Same as U35, plus: a stalled tool prompt is a hang, so the broker's cap kills the process and the ask fails with
"Antigravity stopped answering"; the seat's own timeout is a second bound, never the only one.

## Acceptance (on go)

- Discovery reports a dangling `agy` link as broken and not found.
- The adapter argv carries the read-only and no-MCP switches from step 0 and never `--dangerously-skip-permissions`.
- A stub `agy` that never exits is killed at the seat cap and the ask fails with the stall reason.
- Per-run home and usage tests as in U35, with Antigravity's paths.
