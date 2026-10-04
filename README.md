

# Task Manager on Azure

A Flask task-management API, containerised and deployed to **Azure Container Apps**, with all infrastructure in **Terraform**, HTTPS on a custom domain through **Azure Application Gateway** and **Cloudflare**, and automated deployments from **GitHub Actions**.

**Live:** [https://tm.amatechvault.com](https://tm.amatechvault.com)

> The infrastructure is torn down between working sessions to control cost, so the link may be offline. See [Rebuilding from scratch](#rebuilding-from-scratch).

---

## Architecture

> **Diagram:** _to be added to `docs/`_

### How a request reaches the app

```
Browser
  │  HTTPS, Cloudflare's public edge certificate
  ▼
Cloudflare (DNS + proxy, SSL mode: Full (strict))
  │  HTTPS, validated against a Cloudflare Origin Certificate
  ▼
Azure Application Gateway (Standard_v2, own subnet in a VNet, static public IP)
  │  HTTPS, Host header rewritten to the Container App's own hostname
  ▼
Azure Container App (Consumption plan, scales 0 → 1)
  │  image pulled using a user-assigned managed identity (AcrPull)
  ▼
Azure Container Registry
```

### How a code change reaches production

```
git push to main (changes under app/)
  ▼
GitHub Actions: logs in to Azure via OIDC (no stored passwords)
  ▼
docker build, tag with the commit SHA, push to ACR       (identity has AcrPush on ACR)
  ▼
az containerapp update --image <new tag>                 (identity has Contributor on the Container App only)
```

Logs from the Container Apps environment go to a Log Analytics workspace.

---

## Screenshots

**Live app on the custom domain**

![Live app at tm.amatechvault.com](Screenshots/Screenshot%202026-10-05%20at%2000.34.44.png)

**Azure resources in the resource group**

![Resources in rg-acs-project](Screenshots/Screenshot%202026-10-04%20at%2022.54.03.png)

**Azure Resource Visualizer**

![Resource visualizer](Screenshots/Screenshot%202026-10-04%20at%2022.54.30.png)

**The pipeline's identity has no stored secrets.** The GitHub Actions app registration has zero client secrets and one federated credential: the OIDC trust that lets GitHub Actions log in to Azure without a password.

![Federated credential on the GitHub Actions app registration](Screenshots/Screenshot%202026-10-05%20at%2000.23.39.png)

**CI/CD: first successful deploy (manually triggered)**

![Pipeline run 3](Screenshots/Screenshot%202026-10-04%20at%2023.54.11.png)

**CI/CD: deploy triggered automatically by a push**

![Pipeline run 4](Screenshots/Screenshot%202026-10-05%20at%2000.14.56.png)

---

## Repository layout

```
app/                    Flask app, Dockerfile, .dockerignore
terraform/
  providers.tf          azurerm + azuread providers
  variables.tf          input variables (cert password, marked sensitive)
  resource_group.tf     resource group
  container_registry.tf Azure Container Registry
  container_apps.tf     Log Analytics, Container Apps environment, ACR pull identity, Container App
  networking.tf         VNet, App Gateway subnet, public IP, Application Gateway
  github_actions.tf     OIDC identity for the pipeline and its role assignments
.github/workflows/
  deploy.yml            build, push and deploy pipeline
docs/
  progresslog.md        session-by-session build log
  learning-notes.md     reusable techniques and gotchas, by topic
Screenshots/            screenshots used above
```

Not committed (gitignored): `terraform/terraform.tfvars`, `terraform/certs/` (Origin Certificate, private key, `.pfx`), and Terraform state.

---

## Key decisions

| Decision | Why |
|---|---|
| **Application Gateway**, not Front Door | More hands-on networking (VNet, subnet, listeners, backend pools, health probes), which was a learning goal of the project. |
| **Cloudflare Origin Certificate** on the Application Gateway | Free and trusted by Cloudflare. Avoids building Key Vault + Let's Encrypt automation just to get a cert onto the gateway. The Cloudflare record is proxied with SSL mode **Full (strict)**, so Cloudflare verifies that certificate on every request. |
| **No stored credentials anywhere** | ACR admin user is disabled. The Container App pulls images with a managed identity; GitHub Actions logs in with an OIDC federated credential instead of a client secret. |
| **User-assigned** identity for image pulls | A system-assigned identity doesn't exist until the Container App is created, but the first image pull happens *during* creation, so it can never be granted `AcrPull` in time. A separate identity can be created and authorised first. |
| **Least-privilege pipeline roles** | `AcrPush` on the registry plus `Contributor` scoped to the single Container App, not the resource group or subscription. |
| **Images tagged with the commit SHA** | Every running image traces back to an exact commit. `v1` is only used for the very first deployment. |
| **Pipeline owns the image, Terraform owns everything else** | `lifecycle { ignore_changes = [template[0].container[0].image] }` stops `terraform apply` from rolling back pipeline deployments to `v1`. |
| **Pipeline deploys the app only; infrastructure changes are manual** | Terraform state is local. Running `apply` from CI safely needs remote state first. See [Future work](#future-work). |
| **`max_replicas = 1`, `min_replicas = 0`** | Tasks are stored in memory, so a second replica would have its own separate task list. Scaling to zero keeps idle cost near nothing. |

### Why no Terraform modules

This is one project with one environment and nothing repeated, so a module would be abstraction without reuse. Resources are instead split into one file per concern. Modules would earn their place once there are multiple environments built from the same pattern (see [Future work](#future-work)).

---

## Deploying a change

Push a change under `app/` to `main`. The pipeline builds, pushes and deploys automatically.

To redeploy without changing code, trigger it manually:

```bash
gh workflow run deploy.yml --repo amo541/acs-project
gh run watch --repo amo541/acs-project
```

or use **Actions → Build and Deploy → Run workflow** in GitHub.

---

## Rebuilding from scratch

The steps and gotchas below are what it takes to go from nothing to a working deployment.

**Prerequisites (local, not in git):**
- `terraform/certs/appgw.pfx`: the Cloudflare Origin Certificate and key, converted with:
  ```bash
  openssl pkcs12 -export -out certs/appgw.pfx \
    -inkey certs/cf-origin-key.pem -in certs/cf-origin-cert.pem \
    -password pass:<password>
  ```
- `terraform/terraform.tfvars` containing `appgw_cert_password = "<password>"`
- Azure CLI logged in (`az login`)

**Steps:**

1. `cd terraform && terraform init && terraform apply`
2. **The first apply fails at the Container App.** It points at `coderco-task-app:v1`, but the new registry is empty. Push the image:
   ```bash
   az acr login --name acracsproject
   docker build -t acracsproject.azurecr.io/coderco-task-app:v1 ./app
   docker push acracsproject.azurecr.io/coderco-task-app:v1
   ```
3. Run `terraform apply` again. If it reports the Container App **already exists**, the failed attempt left it behind without recording it in state. Delete it and re-apply:
   ```bash
   az containerapp delete --name acs-project-app --resource-group rg-acs-project --yes
   terraform apply
   ```
4. The Application Gateway gets a **new public IP** on every rebuild. Update the `tm` A record in Cloudflare (keep it **proxied**):
   ```bash
   az network public-ip show -g rg-acs-project -n acs-project-public-ip --query ipAddress -o tsv
   ```
5. **On a brand-new subscription**, resource providers may need registering first, otherwise applies fail with `MissingSubscriptionRegistration`:
   ```bash
   az provider register --namespace Microsoft.ContainerRegistry
   az provider register --namespace Microsoft.App
   az provider register --namespace Microsoft.OperationalInsights
   az provider register --namespace Microsoft.Network
   ```

**Tearing down:** `terraform destroy`. The `azurerm` provider sometimes errors while *waiting* for the Container App or its environment to delete (`polling support for the Content-Type "" was not implemented`) even though the delete is still going ahead in Azure. Check with `az containerapp env show ...` and re-run `terraform destroy` once it's gone.

The GitHub Actions secrets (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) only need updating if the pipeline's app registration is destroyed and recreated, which changes the client ID.

---

## Running locally

```bash
cd app
python3 -m venv .venv
source .venv/bin/activate
pip3 install -r requirements.txt
python3 app.py
```

The app listens on `http://localhost:3000`.

Or in Docker:

```bash
cd app
docker build -t coderco-task-app .
docker run -p 3000:3000 coderco-task-app
```

### API

Task IDs are UUIDs returned when a task is created.

```bash
# Create a task
curl -X POST -H "Content-Type: application/json" -d '{"title":"New Task"}' http://localhost:3000/tasks

# List tasks
curl http://localhost:3000/tasks

# Get one task
curl http://localhost:3000/tasks/<task-id>

# Update a task
curl -X PUT -H "Content-Type: application/json" -d '{"completed":true}' http://localhost:3000/tasks/<task-id>

# Delete a task
curl -X DELETE http://localhost:3000/tasks/<task-id>
```

Swap `http://localhost:3000` for `https://tm.amatechvault.com` to hit the live deployment.

---

## Future work

Deliberately left out of scope for now. The full reasoning is in [`docs/progresslog.md`](docs/progresslog.md).

- **Remote Terraform state** (Azure Storage with state locking). This is the prerequisite for everything below.
- **Infrastructure through CI:** `terraform plan` on every pull request, `apply` on merge, behind branch protection.
- **Multiple environments** (dev → UAT → prod), promoting the same image through each with an approval gate before prod.
- **Persistent storage.** Tasks live in memory and disappear on restart or scale-to-zero; a database would also allow more than one replica.
- **A test step** in the pipeline, and newer `actions/checkout` / `azure/login` versions to clear the Node.js 20 deprecation warning.
- **Flask's development server** with `debug=True` runs in production. A production WSGI server such as Gunicorn would replace it.

---

## Further reading

- [`docs/progresslog.md`](docs/progresslog.md): how the project was built, session by session, including what went wrong and why.
- [`docs/learning-notes.md`](docs/learning-notes.md): reusable techniques picked up along the way, organised by topic.
