# Working on ncode

Notes for coding agents working in this repository.

## UI changes: five directions, then judge

Every change to the UI goes through this process, whether or not anyone asks for it:

1. **Launch five subagents in parallel**, each exploring a *different* way to do the same thing. Make the directions distinct, not five variations of one idea.
2. **Each subagent produces:**
   - a visual mockup: a static HTML page that links the real stylesheet (`Resources/web/app.css`), showing the key states (for example idle, busy, warning, dark mode);
   - a short spec: the idea, the states, the interactions, an implementation sketch, and the design's own biggest weakness.
   - Subagents don't edit the repo; they only write their mockup files.
3. **The main agent orchestrates and judges.** It looks at all five mockups, compares them in a short table, picks one, and borrows the best parts of the runners-up.
4. **The main agent finalizes:** it builds the chosen design, tests it, and ships it.

Changes that aren't UI (process management, protocol handling, data plumbing) can be built directly.

## Privacy: this repo is public

- Before every commit and push, scan the staged diff and the commit metadata for secrets, keys, tokens, home-directory paths, usernames, emails, and the names of private projects or organizations.
- Never commit screenshots or test data taken from a real machine (sidebars, transcripts and project names reveal private work). Use made-up sample data in mockups and tests.
- Commits use the GitHub noreply address, set in this repository's git config.

## Build and test

- `./build.sh` builds `build/ncode.app`. `./build.sh --install` also copies it to `/Applications` and installs the `ncode` command.
- Don't quit or overwrite a running copy of the app while it has chats open; check for child `claude` processes first.
- The chat UI lives in `Resources/web/`. Syntax-check it with `node --check Resources/web/app.js`, and test rendering in a browser by replaying recorded `stream-json` events into `window.__recv`.
