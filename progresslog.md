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

## 2026-10-04 — Rebuilding after the gap, decision on domain strategy

Picked back up after about 3 weeks away. Azure credit (£147.25) is now 4 days from expiry — flagged this, but decided not to let it force a rushed networking setup; covering any overage cost is fine, destroying between sessions stays good practice regardless of the deadline pressure.

- Resolved the open "need a real domain" question: have a Cloudflare account but no domain registered yet. Decided on **Azure Front Door** over Application Gateway for the upcoming HTTPS/custom-domain phase — Front Door can auto-issue/manage the TLS certificate for a custom domain, App Gateway requires sourcing and managing the cert yourself. Noted for later: the Cloudflare DNS record for the domain needs to be **DNS-only (grey cloud), not proxied**, or Azure's domain validation and TLS will conflict with Cloudflare's proxy.
- `terraform apply` to rebuild the base infra (RG, ACR, Log Analytics, environment, container app, identity, role assignment) hit the exact same two issues as the first build:
  - ACR came back empty (expected — Terraform manages the registry, not its contents) — re-pushed `coderco-task-app:v1`.
  - Same orphaned-container-app pattern as before (control plane creates it, revision/image-pull fails, Terraform's state never records it) — same fix, `az containerapp delete` then re-apply.
- **New issue, not seen before**: after a clean re-apply, `terraform plan` showed perpetual drift — Azure now auto-attaches a default `"Consumption"` workload profile to Container App Environments/Apps that didn't exist (or wasn't exposed this way) when this was first built weeks ago. Fixed by explicitly declaring `workload_profile {}` on the environment and `workload_profile_name = "Consumption"` on the container app, matching reality instead of letting Terraform fight the platform default. Another real example of Azure's defaults shifting under an existing config over time.
- Confirmed app reachable again on its new default hostname (`*.gentleforest-....azurecontainerapps.io` — new random suffix, as expected from a full rebuild).

## Next up

## 2026-10-04 (continued) — Switched plan: Application Gateway, not Front Door

Registered `amatechvault.com` on Cloudflare. Decided against the earlier Front Door plan — no longer under time pressure (Azure credit deadline no longer treated as a hard constraint), so went with the more hands-on **Application Gateway** route instead, since it's a better fit for the networking fundamentals this whole project is meant to consolidate.

- **TLS strategy**: rather than sourcing a publicly-trusted cert (would need Key Vault + Let's Encrypt/ACME automation — a whole side-project), used a **Cloudflare Origin Certificate** instead — free, covers `*.amatechvault.com` + apex, trusted automatically by Cloudflare. Converted the cert+key Cloudflare gives you into a `.pfx` via `openssl pkcs12 -export` (App Gateway's `ssl_certificate` block needs that format). Cert/key files kept in `terraform/certs/`, added to `.gitignore` (`*.pem`, `*.key`, `*.pfx`, the whole folder) *before* any files existed, to close the window for an accidental secret commit.
- Introduced `variables.tf` + `terraform.tfvars` properly for the first time (planned a few sessions back, finally had a real reason to): the `.pfx` password as a `sensitive = true` variable, kept out of committed files.
- Built `networking.tf` incrementally, same lesson as Container Apps — simple pieces first (VNet, dedicated subnet, Standard static public IP — all hard platform requirements for App Gateway v2, not design choices), confirmed clean, *then* the big `azurerm_application_gateway` resource.
- `azurerm_application_gateway` was a real jump in complexity — unlike every other resource so far, its internal blocks (listener, backend pool, HTTP settings, etc.) cross-reference each other by **plain name strings**, not Terraform's usual dot-notation resource references. Worth remembering as the exception to the pattern, not the rule.
- Key correctness detail: `pick_host_name_from_backend_address = true` on the backend HTTP settings — without it, App Gateway would forward the original `Host: tm.amatechvault.com` header straight to the Container App, which wouldn't recognize it. This rewrites the Host header to the backend pool's actual FQDN before forwarding.
- Hit the familiar `MissingSubscriptionRegistration` pattern again, this time for `Microsoft.Network` — registered and retried, same as every previous new-namespace case.
- **DNS + Cloudflare setup**: added an `A` record for `tm` → the App Gateway's public IP, **proxied (orange cloud)** this time — opposite of the Front Door plan, since here Cloudflare's edge cert covers the public-facing leg and the Origin Cert only secures Cloudflare→App Gateway. Set Cloudflare SSL/TLS mode to **Full (strict)** — the only mode that actually validates the Origin Cert, which is the whole reason it was generated.
- **Confirmed working end-to-end**: `https://tm.amatechvault.com` loads the full app in the browser, through Cloudflare → Application Gateway → Container App. Phase 2 (HTTPS + custom domain) complete.

## 2026-10-04/05 — CI/CD pipeline (GitHub Actions + OIDC)

**Design decisions made up front:**
- **OIDC federated credential, not a client secret.** GitHub Actions swaps a short-lived GitHub token for an Azure session, so there's no password stored anywhere. Consistent with the "no static credentials" approach used for the ACR pull identity.
- **The pipeline's identity is itself managed in Terraform** (new `azuread` provider, v3.x) rather than created by hand with `az ad` commands: `azuread_application_registration`, `azuread_service_principal`, `azuread_application_federated_identity_credential`, plus `azurerm_role_assignment`s. Verified resource/attribute names against the provider's raw docs on GitHub (the Registry pages don't fetch cleanly), which caught that v3.x uses `azuread_application_registration` rather than the older bundled `azuread_application`.
- **Scope: build/push/deploy the app only.** Infrastructure changes stay manual (`terraform apply` from the laptop). See Future work below for why that's the consistent choice while state is still local.

**What was built:** `terraform/github_actions.tf` (identity + roles) and `.github/workflows/deploy.yml`, which triggers on pushes to `main` under `app/**` (plus a manual `workflow_dispatch` button), logs in via OIDC, builds the image, tags it with the commit SHA (instead of reusing `v1`, so every running image traces back to an exact commit), pushes to ACR, and runs `az containerapp update`.

**Deliberately reached the permission failure manually, for learning.** Gave the identity only `AcrPush` at first, knowing the deploy step would fail, to see it happen for real:
1. **First run failed earlier than expected, at Azure login.** `AADSTS700213: No matching federated identity record`. GitHub's OIDC subject now includes immutable numeric IDs (`repo:amo541@182442816/acs-project@1361986982:ref:refs/heads/main`), not just names, so the name-only subject from older docs never matched. Fixed by copying the exact subject from the error. The IDs can also be looked up in advance with `gh api`.
2. **Second run reached the planned failure.** Build and push went green (so `AcrPush` worked), then deploy failed with `The containerapp 'acs-project-app' does not exist`. It *did* exist. Azure answers "not found" rather than "access denied" when an identity has no rights on a resource at all. Lesson: when a pipeline says a resource doesn't exist but you know it does, suspect permissions first.
3. **Fix:** a `Contributor` role assignment scoped to *just* the Container App (not the resource group). Third run: all green.

**New problem the success created:** `terraform plan` then wanted to roll the app back from the pipeline's commit-SHA image to `v1`. Terraform and the pipeline both "owned" the image field. Fixed with `lifecycle { ignore_changes = [template[0].container[0].image] }`: Terraform sets `v1` on first creation, then leaves the image to the pipeline while still managing everything else.

**Skills picked up:** debugging Actions from the terminal with the `gh` CLI (`gh run list`, `gh run view --log-failed`, `gh run watch`, `gh workflow run`), finding run IDs, and `terraform fmt`. All collected by topic in a new [`docs/learning-notes.md`](docs/learning-notes.md), a reference companion to this chronological log.

## Future work (documented, deliberately not built)

These are the "enterprise route" items discussed while designing the pipeline. They were scoped out on purpose, not overlooked.

1. **Pipeline-driven infrastructure (plan on PR, apply on merge).** Mature teams usually have CI run `terraform plan` on every pull request and post the diff for review, then run `apply` automatically on merge to `main`, rather than anyone applying from a laptop. Prerequisites:
   - **Remote state** (an Azure Storage Account blob with state locking). CI runners are ephemeral and can't rely on a local `terraform.tfstate`. This is the real blocker, and why manual applies are the *consistent* choice while state is local.
   - A **separate, more broadly-scoped identity** for infra (closer to `Contributor` on the resource group), which is a bigger blast radius than the narrow app-deploy identity.
   - **Branch protection / required reviews** on `main`, so no infra change applies without a human approving it. That's what turns automation into an audit trail.
2. **Multiple environments (dev → UAT/staging → prod).** Standard practice is to build the image *once* and promote the same image through each environment, usually with a manual approval gate before prod. Here that would mean a resource group (or at least a Container App) per environment, driven by per-environment `.tfvars` files or Terraform workspaces sharing the same `.tf` code, plus GitHub Environments with required reviewers on the prod deploy job.

## 2026-10-05 — `.dockerignore`, screenshots, README

- **`.dockerignore`**, finally closing the oldest open item from day one. Saw the problem first: `docker run --rm coderco-task-app ls -la /app` showed an 11 MB macOS `venv/`, `.DS_Store` and the `Dockerfile` baked into the image by `COPY . .`. First attempt put several patterns on one line separated by commas, which Docker treats as a single literal pattern matching nothing; fixed to one pattern per line. After: `/app` in the image dropped to 264K, and only the `COPY . .` layer rebuilt (the `pip install` layer stayed cached).
- Learned that **Docker doesn't read `.gitignore`**. CI images were already clean because the GitHub runner only has what's in git; local builds weren't. Also that the build output's `transferring context:` size is a poor measurement, because Docker caches the context between builds.
- Committing `app/.dockerignore` **triggered the pipeline automatically**, the first push-triggered (rather than manual) deploy. It went green.
- Screenshots committed to `Screenshots/`: live site, Azure resources and resource visualizer, the browser's view of the certificate (Cloudflare's Let's Encrypt edge cert, which is exactly what should be visible, since the Origin Cert only secures Cloudflare → Azure), and pipeline runs #3 and #4.
- **README rewritten** to describe the actual deployment: live URL, request and deploy flow, screenshots, key decisions, deviations from the brief (`.com` domain, no modules, no test step), a rebuild-from-scratch runbook with every gotcha hit along the way, local dev and API usage, and future work.

## Next up

- Architecture diagram (building this myself) → add to `docs/` and replace the placeholder in the README.
- Final reflection section in this log.
- Housekeeping: remove the stray root-owned `terraform/provider.tf.save`.
- Optional: a basic test step in the pipeline, and newer `actions/checkout`/`azure/login` versions to clear the Node.js 20 warning.
