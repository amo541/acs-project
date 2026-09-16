# Progress Log — CoderCo Azure Project

Running log of what's been done, decisions made, and things learned along the way. Kept up to date at the end of each session so it's easy to pick back up, and doubles as a reflection piece once the project's done.

---

## 2026-09-06 — Local app baseline

- Cloned the assignment repo, reviewed `app/app.py`: Flask task-management API, CRUD endpoints (`/tasks`), in-memory storage (a plain Python dict — no DB), runs on port **3000**, `debug=True`.
- Set up a Python venv in `app/`, installed `requirements.txt`, ran the app locally, confirmed CRUD works end-to-end via `curl` (`POST /tasks`, `GET /tasks`).
- Noted two things to keep in mind for later: in-memory storage means tasks vanish on restart/across replicas (relevant once this runs on Container Apps with multiple instances), and `debug=True` is dev-only.

## 2026-09-06/07 — Dockerizing the app

- Wrote `app/Dockerfile`. First draft had two issues, caught in review rather than just handed a fix:
  - `EXPOSE 5000` didn't match the app's actual port (3000) — Flask's *default* is 5000, but this app overrides it. Fixed to `EXPOSE 3000`.
  - Unused multi-stage build syntax (`FROM python:3.9-slim as Build`) with no second stage referencing it — removed since it wasn't doing anything.
- Confirmed the caching-order principle: `COPY requirements.txt .` + `RUN pip install` *before* `COPY . .`, so code changes don't invalidate the dependency-install layer on every rebuild.
- Built and ran the image locally (`docker build`, `docker run -p 3000:3000`), re-ran the same `curl` tests against the containerized app — confirmed working.
- `.dockerignore` still outstanding (deliberately deferred).

## 2026-09-08 — Manual Azure setup (before Terraform)

Rationale: doing this manually once first, before automating it in Terraform, so the mechanics (auth, resource fields, registry behavior) are understood rather than abstracted away from day one.

- Installed Azure CLI via Homebrew (had to update Xcode Command Line Tools first — unrelated prerequisite issue).
- `az login`, confirmed subscription ("Azure subscription 1").
- Created resource group `rg-acs-project` (region: uksouth).
- Hit `MissingSubscriptionRegistration` creating the registry — first-time-use snag, fixed with `az provider register --namespace Microsoft.ContainerRegistry`. Noted this will likely recur for other namespaces later (e.g. `Microsoft.App` for Container Apps, `Microsoft.Network` for the gateway).
- Created ACR `acscontainer1` (Basic SKU).
- Authenticated Docker against it (`az acr login`), tagged the local image (`docker tag ... acscontainer1.azurecr.io/coderco-task-app:v1`), pushed successfully — confirmed visible in both CLI output and the Azure Portal.
- Checked Azure free credit: **£147.25, expires 2026-10-08** — effectively a one-month deadline for the whole project. Since RG + ACR cost is negligible, but Container Apps/App Gateway will meter continuously once they exist, plan is to `terraform destroy` between sessions from that point on.

## 2026-09-09 — Own GitHub repo

- Original clone's `origin` pointed at `codercohq/coderco-azure-project` (read-only upstream, not push-able).
- Installed GitHub CLI (`gh`) via Homebrew, authenticated (`gh auth login`).
- Committed the Dockerfile, created a new **private** repo under my own account — [github.com/amo541/acs-project](https://github.com/amo541/acs-project) — added as remote `myrepo`, pushed. `main` now tracks `myrepo/main` by default; `origin` (upstream) kept around in case codercohq pushes updates later.

## 2026-09-16 — Terraform for resource group + ACR

- Quick Terraform workflow refresher (providers, state, init/plan/apply/destroy) since a week had passed.
- Destroyed the manually-built `rg-acs-project` (`az group delete`), freeing up the ACR name for a clean rebuild.
- Wrote `terraform/provider.tf` and `terraform/main.tf`. Mistakes caught in review along the way, not just handed fixes:
  - `provider.tf`: unclosed `terraform {}` block (syntax error), then missing the mandatory `provider "azurerm" { features {} }` block (required_providers alone only tells Terraform which plugin to download, doesn't configure it).
  - `main.tf`: resource *local* names used hyphens (works, but convention is underscores — hyphens reserved for the actual cloud resource `name =` values); ACR `name` briefly had hyphens in it, which Azure rejects (ACR names must be alphanumeric-only); `admin_enabled` was `true` via VS Code autocomplete, not intentional — changed to `false` to match how the manual ACR was actually authenticated (`az acr login`, not static admin credentials). Decided proper CI/CD auth will use a scoped service principal/managed identity (`AcrPush` role) later, not ACR admin creds.
- `terraform init` → `plan` → `apply` succeeded cleanly (2 added, 0 errors) — new resource group + ACR (`acracsproject`) match the manually-built version exactly (name, region, SKU, admin disabled).
- Re-pushed `coderco-task-app:v1` to the new Terraform-created registry to confirm parity end-to-end.
- Committed `terraform/` (provider.tf, main.tf, lock file) to the repo — `.gitignore` already correctly excludes `.terraform/` and `*.tfstate*`, confirmed before committing.
- Noted a stray root-owned `terraform/provider.tf.save` file sitting in the directory (harmless, gitignored, cause unclear — maybe a stray `sudo vim` session) — not investigated yet.

## 2026-09-16 (continued) — File reorganization

- Split the flat `terraform/` layout into per-concern files (enterprise-style convention): `providers.tf` (renamed from `provider.tf`), `resource_group.tf`, `container_registry.tf`. Confirmed the split was purely cosmetic with `terraform plan` → "No changes."
- Learned the actual reason this matters at scale: separate state per project (not per file) is what isolates blast radius between unrelated projects — file splitting is just readability within one project/state, a different axis entirely.
- Minor detour: git commit heredocs kept breaking in this shell environment (`<noreply@...>` was being parsed as shell redirection) — worked around by writing commit messages to a file and using `git commit -F`. Also: **no more "Co-Authored-By: Claude" lines in commits/PRs going forward**, per explicit request.

## 2026-09-16 (continued) — Azure Container Apps

First real Azure Container Apps deployment — new service, more moving parts than ACR. Built incrementally in `terraform/container_apps.tf`:

- **Log Analytics workspace** + **Container App Environment** — straightforward once the resource-group-reference pattern (avoiding hardcoded literals/drift) was applied consistently, same lesson as before, just repeated in two more places.
- **`azurerm_container_app`** — this is where the real learning happened. Iterated through:
  - `resource_group_name` accidentally hardcoded as a literal string again — caught and explained as "drift risk" (config silently disagreeing with itself if the RG is ever renamed).
  - Learned to read the Terraform Registry docs' "Attributes Reference" section to find `azurerm_container_registry`'s `login_server` attribute, rather than being handed it — built the `image` value via string interpolation.
  - **Provider version bug, caught live**: `azurerm` v5.x (pulled in by the loose `>= 3.0.0` constraint flagged back on 2026-09-16 earlier) requires an explicit `logs_destination = "log-analytics"` alongside `log_analytics_workspace_id` — didn't exist as a requirement in older versions. Direct proof of why loose version constraints bite later.
  - **The real conceptual hurdle**: system-assigned identity + ACR pull is a chicken-and-egg problem. Azure tries to pull the image *during* container app creation, but a system-assigned identity's principal ID (and therefore any role assignment granting it access) doesn't exist until *after* that same resource finishes creating — too late for the first pull. First `apply` failed with `UNAUTHORIZED` on the image pull.
  - **Fix**: switched to a standalone `azurerm_user_assigned_identity`, created and granted `AcrPull` *before* the container app exists, then attached via `identity { type = "UserAssigned" }` + an explicit `registry { server = ..., identity = ... }` block telling Container Apps which identity to use for that specific registry.
  - **Side effect of the earlier failed apply**: the container app resource had actually been created in Azure (control-plane succeeded even though the revision/image pull failed), but Terraform's state never recorded it since the apply call errored — a state/reality mismatch. Resolved by deleting the orphaned resource directly (`az containerapp delete`) rather than importing a broken, wrongly-configured resource into state.
- Final `apply` succeeded cleanly. Confirmed the app is reachable over HTTPS on its default `*.azurecontainerapps.io` hostname — full path from Dockerfile → ACR → Container App now proven end-to-end via Terraform.

## 2026-09-16 (continued) — Cost cleanup: `terraform destroy`

- Confirmed the running setup wasn't actually costing much (Container App had `min_replicas = 0`, so it scales to zero when idle — the always-on cost concern applies more to what's coming next, App Gateway/Front Door, than to what existed today). Destroyed anyway to build the habit before it actually matters.
- Hit a real `azurerm` provider bug (not a config mistake): deleting `azurerm_container_app` and later `azurerm_container_app_environment` both failed with `polling support for the Content-Type "" was not implemented` — a provider polling quirk unrelated to whether the delete itself actually succeeded on Azure's side. Worked around by checking actual resource state directly via `az containerapp show` / `az containerapp env show` between retries, rather than trusting Terraform's error as the final word. Environment deletion in particular took several minutes server-side regardless.
- End state confirmed clean: `az group exists --name rg-acs-project` → `false`. Nothing billable left running.

## Next up

- Re-`apply` the existing Terraform config to bring everything back (expect: need to `docker push` the image again since the fresh ACR is empty, and the Container App's default hostname will have a new random suffix).
- HTTPS networking with a custom domain (Application Gateway or Front Door) to satisfy the `tm.<domain>.co.uk` requirement — still need to sort out an actual domain for this.
- Then the CI/CD pipeline, using a proper service principal (not admin credentials) for ACR push access.
