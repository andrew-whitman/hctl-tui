# hctl-tui

Terminal UI / CLI that runs a Harness test matrix. Default mode **replays GitHub webhook triggers** as pipeline executes: fetch trigger config → resolve `inputYaml` → `hctl pipeline-execute … --body @file`. Optional `type: custom` still POSTs Harness custom webhooks. Built on [`hctl`](https://github.com/ianmatson/harness-cli) (auth) and [`gum`](https://github.com/charmbracelet/gum) (prompts).

It does **not** edit templates, commit, or push.

## Install

### Recommended: `uv tool`

```bash
uv tool install git+https://github.com/andrew-whitman/hctl-tui.git
hts --help
```

Upgrade later:

```bash
uv tool upgrade hctl-tui
# or reinstall from git tip:
uv tool install --force git+https://github.com/andrew-whitman/hctl-tui.git
```

Still need **zsh** on PATH. Peer tools (**gum**, **hctl**) are installed automatically by `hts init` when missing (`hctl` via `uv tool install` when possible; `gum` via Homebrew or a GitHub release binary into `~/.local/bin`).

### From a git checkout

```bash
git clone https://github.com/andrew-whitman/hctl-tui.git
cd hctl-tui
./setup.sh
export PATH="$HOME/.local/bin:$PATH"   # if needed
```

Or editable with uv:

```bash
uv tool install --editable .
```

## Quick start

```bash
uv tool install git+https://github.com/andrew-whitman/hctl-tui.git
hts init           # installs gum/hctl if needed, writes config, runs hctl auth
hts                # interactive TUI
```

Use `hts init --skip-deps` to skip installs, or `hts doctor --fix-deps` to (re)install peers later.

Non-interactive:

```bash
hts run --module ci --dry-run
hts run --module ci --tech java --set shared
hts run --module ci --branch main
hts run --module ci --alias a1,a2          # specific pipelines (CLI)
hts run --module ci --watch --fetch-logs   # poll until done, then download logs
# TUI: Run test suite → Select pipelines (space to toggle checklist)
#      After a real run: Watch executions? → Fetch logs?
hts logs --execution-id ID \
  --pipeline-org ORG --pipeline-project PROJ --pipeline-id PIPE \
  --alias my-alias                         # → ./hts-logs/my-alias/ID/
hts matrix list --module ci
hts matrix add --module ci \
  --type github --alias my-alias --trigger YOUR_TRIGGER_ID \
  --tech java --set shared \
  --pipeline-org YOUR_ORG --pipeline-project YOUR_PROJECT --pipeline-id YOUR_PIPELINE_ID
hts matrix edit --module ci --alias my-alias --set shared
hts matrix remove --module ci --alias my-alias
hts profile list
hts profile use default
hts export --out ./my-suite          # matrices + redacted profile stubs
hts import ./my-suite --as sandbox   # remap into profile "sandbox"
hts doctor
```

## Config

| Path | Purpose |
|------|---------|
| `~/.config/hctl/config.json` | Auth (host, account, API key) — owned by **hctl** |
| `~/.config/hctl-tui/config.yaml` | Active profile pointer + UI defaults |
| `~/.config/hctl-tui/matrices/<profile>/<module>.yaml` | Test matrices |
| `~/.config/hctl-tui/branch-history.yaml` | Recently used app/source branches (per pipeline; local unless exported) |

### Export / import

Share matrices (and optional hctl profile stubs) between machines:

```bash
hts export --out ./hts-bundle              # active profile; API keys redacted
hts export --profile all --out ./all       # every profile
hts export --out ./hts-bundle --with-branch-history   # also copy recent branches
hts import ./hts-bundle                    # merge; skip existing files
hts import ./hts-bundle --as other --force # remap + overwrite
hts import ./hts-bundle --with-branch-history         # merge branch history too
```

Bundle layout: `manifest.yaml`, `matrices/<profile>/*.yaml`, `profiles/<name>.json` (no `api_key` unless `--include-secrets`), optional `branch-history.yaml`. After import, set the API key with `hts profile init`.

See [hctl-tui-spec.md](hctl-tui-spec.md) for the full contract.

### Watch + logs

After firing a matrix, `hts run --watch` polls Harness until each captured execution is terminal (or `--watch-timeout` seconds). Add `--fetch-logs` to download full-pipeline console logs into:

```text
./hts-logs/<alias>/<planExecutionId>/
  meta.json
  logs.zip
  extracted/     # when unzip is available
```

Override the root with `HTS_LOGS_DIR` or `hts logs --out DIR`. Fetch a single execution anytime with `hts logs --execution-id …`. Logs from still-running executions are refused unless `--force` (may be incomplete). Harness limits downloads to 100 log files per request.

## Dependencies

- zsh (runtime for the TUI/CLI scripts)
- gum (charmbracelet)
- hctl (harness-cli)
- Python ≥ 3.9 (provided by `uv tool install`; pulls in PyYAML)

`yq` is optional when PyYAML is available. `./setup.sh` can still install gum / hctl / yq via Homebrew for checkout-based installs.
