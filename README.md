# ocicl-bot

Automated ingestion of new Common Lisp projects into [ocicl](https://github.com/ocicl).

Monitors [quicklisp-projects issues](https://github.com/quicklisp/quicklisp-projects/issues) for new package requests, validates them, and creates ocicl repos with the standard structure. Built on [cl-workflow](https://github.com/atgreen/cl-workflow) for durable workflow execution.

## What it does

For each new issue:

1. **Parse** -- LLM extracts project name, git URL, and description from free-text issue
2. **Content check** -- flags offensive, political, religious, libelous, or illegal content for manual review
3. **Duplicate detection** -- skips if already processed in this batch
4. **Upstream validation** -- rejects unreachable URLs and forks, warns on missing license
5. **System check** -- rejects if system names collide with existing ocicl systems or CL builtins
6. **Create/fix repo** -- writes standard ocicl repo structure (README.org, GHA workflow, LICENSE) and pushes
7. **Update registry** -- adds new system names to `all-ocicl-systems.txt`

All steps are durable -- if the process crashes mid-batch, restarting replays completed steps and resumes at the next one.

## Setup

```bash
# One-time setup
mkdir -p ~/.local/etc/ocicl-bot ~/.local/share/ocicl-bot
cp app-key.pem ~/.local/etc/ocicl-bot/
echo 0 > ~/.local/etc/ocicl-bot/cursor

# Build the container
podman build -t ocicl-bot -f Containerfile .
```

## Usage

```bash
# Run once (processes new issues since last cursor position)
./ocicl-bot-run.sh

# Or via cron (daily at 8am)
# crontab -e
# 0 8 * * * /path/to/ocicl-bot-run.sh >> /var/log/ocicl-bot.log 2>&1
```

## Container layout

| Mount | Container path | Purpose |
|---|---|---|
| `~/.local/etc/ocicl-bot/` | `/config/` | `app-key.pem` (GitHub App key), `cursor` (last issue number) |
| `~/.local/share/ocicl-bot/` | `/data/` | `ocicl-bot.db` (workflow state) |
| `~/ocicl-admin/` | `/ocicl-admin/` | Git checkouts for ocicl repos |

## REPL usage

```lisp
(asdf:load-system :ocicl-bot)

;; Run from cursor
(ocicl-bot:run)

;; Or specify a starting point
(ocicl-bot:run :since 2556)

;; Wait for completion and update cursor
(ocicl-bot:wait-and-save-cursor)
```

## Prerequisites

- GitHub App "ocicl-bot" installed on the ocicl org
- `GEMINI_API_KEY` environment variable (or `~/.local/etc/ocicl-bot/gemini-api-key` file)

## Author and License

ocicl-bot was written by Anthony Green and is distributed under the terms of the MIT license.
