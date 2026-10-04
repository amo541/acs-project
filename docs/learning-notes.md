# Learning Notes

Reusable skills and reference material picked up during this project, organised by topic rather than by date. For the chronological story of the project, see [`progresslog.md`](../progresslog.md).

---

## Debugging GitHub Actions from the terminal (`gh` CLI)

The browser UI is fine for a quick look, but the summary annotations are often useless (e.g. just `Process completed with exit code 3`). The `gh` CLI gets you to the real error in seconds, and works over SSH and in scripts too.

### Core commands

```bash
# 1. List recent runs of a workflow (status + run IDs)
gh run list --repo amo541/acs-project --workflow deploy.yml --limit 3

# 2. Summary of one run: which jobs/steps passed or failed
gh run view <run-id> --repo amo541/acs-project

# 3. Only the logs from the step(s) that failed - the most useful one
gh run view <run-id> --repo amo541/acs-project --log-failed | tail -30
```

`--log-failed` skips every green step and prints only what broke. The actual error is usually near the end, hence `tail`.

### Finding the run ID

- **`gh run list`**: the long number near the end of each line (e.g. `37240566707`). The newest run is the top line.
- **Browser URL**: a run's page ends in `/actions/runs/<run-id>`.
- **Skip it**: inside the repo folder, most `gh run` commands show a picker of recent runs if you leave the ID off (e.g. `gh run view --log-failed`).

### Handy extras

| Command | What it does |
|---|---|
| `gh run view` (no ID, run inside the repo folder) | Interactive picker of recent runs |
| `gh run watch` | Follow a running workflow live in the terminal |
| `gh run rerun <run-id>` | Re-run a run (same as the "Re-run" button) |
| `gh workflow run deploy.yml --repo amo541/acs-project` | Trigger a `workflow_dispatch` run without the browser |

### Trimming output with `--json` / `--jq`

Most `gh` commands can return JSON and filter it, which is useful for scripting or just cutting noise:

```bash
# Just pass/fail and name for every step in the latest run
RUN=$(gh run list --repo amo541/acs-project --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view $RUN --repo amo541/acs-project --json jobs --jq '.jobs[0].steps[] | "\(.conclusion)\t\(.name)"'
```

### Real example from this project

The annotation only said `Process completed with exit code 3`. `--log-failed` immediately showed the real cause:

```
ERROR: The containerapp 'acs-project-app' does not exist
```

That led to the next lesson below.

---

## "Resource does not exist" can mean "you don't have permission"

When an identity has **no** permissions on an Azure resource, Azure often answers *not found* rather than *access denied*. This is deliberate: it stops an attacker from using error messages to discover which resources exist.

In this project the GitHub Actions identity only had `AcrPush` on the container registry, so when the pipeline tried to update the Container App, Azure replied that it "does not exist", even though it was running and serving traffic.

**Rule of thumb:** if a pipeline says a resource doesn't exist but you know it does, check the identity's role assignments before anything else.

---

## GitHub OIDC subject format includes numeric IDs

When setting up an Azure federated identity credential for GitHub Actions, the `subject` has to match the token GitHub sends **exactly**. GitHub now includes immutable numeric IDs alongside the owner and repo names:

```
repo:amo541@182442816/acs-project@1361986982:ref:refs/heads/main
```

not just:

```
repo:amo541/acs-project:ref:refs/heads/main
```

The IDs never change and are never reused, so the trust is pinned to *this* repo and account. A name-only subject could be hijacked if the repo were deleted and someone recreated one with the same name.

### Finding the IDs ahead of time

```bash
# Repo ID and owner (account) ID
gh api repos/amo541/acs-project --jq '{repo_id: .id, owner_id: .owner.id}'

# How this repo's OIDC subject claim is currently configured
gh api repos/amo541/acs-project/actions/oidc/customization/sub
```

If you get it wrong anyway, the Azure login error message prints the exact subject GitHub presented (`AADSTS700213: No matching federated identity record found for presented assertion subject '...'`), so you can copy it from there.
