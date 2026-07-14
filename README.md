# hctl-tui

Terminal UI / CLI that orchestrates Harness **custom webhook triggers** across a test matrix. Built on [`hctl`](https://github.com/ianmatson/harness-cli) (auth + API) and [`gum`](https://github.com/charmbracelet/gum) (prompts).

It does **not** edit templates, commit, or push — trigger-only orchestration.

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

Still need system tools on PATH: **zsh**, **gum**, and **hctl**. Run `hts doctor` after install.

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
uv tool install git+https://github.com/ianmatson/harness-cli.git   # if needed
hts init           # writes hts config + runs hctl auth onboarding
hts                # interactive TUI
```

Non-interactive:

```bash
hts run --module ci --dry-run
hts run --module ci --tech java --set shared
hts matrix list --module ci
hts matrix add --module ci \
  --alias java-shared-feature --trigger feature \
  --tech java --set shared \
  --pipeline-org default --pipeline-project my_proj --pipeline-id my_pipe
hts profile list
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
