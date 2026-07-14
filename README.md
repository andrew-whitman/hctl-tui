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
hts matrix list --module ci
hts matrix add --module ci \
  --type github --alias my-alias --trigger YOUR_TRIGGER_ID --branch main \
  --tech java --set shared \
  --pipeline-org YOUR_ORG --pipeline-project YOUR_PROJECT --pipeline-id YOUR_PIPELINE_ID
hts matrix edit --module ci --alias my-alias --branch develop
hts matrix remove --module ci --alias my-alias
hts profile list
hts profile use default
hts doctor
```

## Config

| Path | Purpose |
|------|---------|
| `~/.config/hctl/config.json` | Auth (host, account, API key) — owned by **hctl** |
| `~/.config/hctl-tui/config.yaml` | Active profile pointer + UI defaults |
| `~/.config/hctl-tui/matrices/<profile>/<module>.yaml` | Test matrices |

See [hctl-tui-spec.md](hctl-tui-spec.md) for the full contract.

## Dependencies

- zsh (runtime for the TUI/CLI scripts)
- gum (charmbracelet)
- hctl (harness-cli)
- Python ≥ 3.9 (provided by `uv tool install`; pulls in PyYAML)

`yq` is optional when PyYAML is available. `./setup.sh` can still install gum / hctl / yq via Homebrew for checkout-based installs.
