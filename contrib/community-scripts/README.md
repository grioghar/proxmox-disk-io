# Offering this to Proxmox VE Helper-Scripts

Working files for proposing this tool to
[community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).

| File | Purpose |
| --- | --- |
| `DISCUSSION.md` | Draft post for their Discussions → **Ideas** category |
| `pve-disk-io.sh` | The `tools/pve/` wrapper, in their house style |

## The route

New scripts are **not** accepted directly into ProxmoxVE — their
`CONTRIBUTING.md` says such PRs "will be closed without review". Everything new
goes to [ProxmoxVED](https://github.com/community-scripts/ProxmoxVED), their
testing repo, and maintainers promote it once accepted.

1. Post `DISCUSSION.md` in **Ideas** and wait for a maintainer's read.
2. If they're interested: fork ProxmoxVED, branch `feat/pve-disk-io`, add
   `pve-disk-io.sh` as `tools/pve/pve-disk-io.sh`, open the PR.
3. On acceptance they move it to ProxmoxVE.

## Notes on the wrapper

- Follows `tools/pve/disk-health.sh`: sources `core.func`, calls
  `load_functions`, registers `init_tool_telemetry "pve-disk-io" "pve"`.
- Reads `var_action` from the environment first and only prompts when it is
  unset, per their "never prompt without an escape hatch" rule.
- Installs the `.deb` from this project's latest GitHub release rather than
  vendoring files into the script.
- `uninstall` uses `apt remove`, not `purge`, so recorded history survives a
  reinstall.

## Verification

- **ShellCheck 0.11.0: clean**, zero findings, both with default rules and with
  the project's own `.shellcheckrc` applied. Their `.shellcheckrc` does not
  disable SC1090 and every one of their own tools trips it via
  `source <(curl ...)`; two `# shellcheck source=/dev/null` directives silence
  it here rather than relying on that being tolerated.
- Tested end to end on Proxmox VE 9.2: `status`, `uninstall`, then `install`
  pulling the release back down and restoring the panel and its endpoints.

Every shell script in this repository is also ShellCheck clean under default
rules.
