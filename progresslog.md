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

## Next up

- Destroy the manually-created `rg-acs-project` resource group and rebuild the same resource group + ACR through Terraform, to compare the IaC output against what was built by hand.
- Then move on to Azure Container Apps, HTTPS networking (Application Gateway or Front Door), and finally the CI/CD pipeline.
