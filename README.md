# ocicl-bot

Automated ingestion of new Common Lisp projects into [ocicl](https://github.com/ocicl).

Monitors [quicklisp-projects issues](https://github.com/quicklisp/quicklisp-projects/issues) for new package requests, validates them, and creates ocicl repos with the standard structure. Built on [cl-flow](https://github.com/atgreen/cl-flow) for durable workflow execution.

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

## Prerequisites

1. GitHub App "ocicl-bot" installed on the ocicl org
2. App private key at `~/.ocicl/app-key.pem`
3. [Gemini CLI](https://github.com/google-gemini/gemini-cli) for LLM parsing

## Usage

```lisp
(asdf:load-system :ocicl-bot)
(ocicl-bot:run 2560)  ; process issues newer than #2560
```

## Author and License

ocicl-bot was written by Anthony Green and is distributed under the terms of the MIT license.
