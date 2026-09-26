# Agents Guide

Quick guide for contributors and AI agents working on `koborin-ai/langfuse`.

## Language Policy

- **Conversation**: Always communicate with the user in **Japanese**.
- **Code**: Write all code, comments, variable names, and commit messages in **English**.

## Mission

- Self-hosted Langfuse at `langfuse.koborin.ai` for koborin.ai demos and experiments.
- One GCE Spot VM (`n-koborinai`, `asia-northeast1`) running Docker Compose, reachable only through a Cloudflare Tunnel.
- Infrastructure is one TerraDart root module, `langfuse`. App files ship with `deploy-app.yml`.

## Rules

1. **No local apply or deploy**: `terraform apply` runs only in `release-infra.yml`; Compose changes reach the VM only through `deploy-app.yml`. Read-only inspection over IAP SSH is fine.
2. **No keys**: GitHub Actions authenticates to GCP with Workload Identity Federation. Never add a service-account key.
3. **No secrets in git or state**: app secrets live in Secret Manager `langfuse-env`, added with `gcloud secrets versions add`. The tunnel token uses a write-only attribute.
4. **State**: R2 bucket `koborin-ai-tfstate`, key `terraform/langfuse/terraform.tfstate`.
5. **Code as documentation**: the stack stays one explicit file (`infra/lib/langfuse_stack.dart`). Environment constants live in `infra/bin/synth.dart`; synth reads only `CLOUDFLARE_ACCOUNT_ID` and `LANGFUSE_OWNER_EMAIL`.
6. **Compose drift from upstream**: `deploy/compose.yaml` lists every difference from the upstream file in its header. Keep that list current when re-syncing.
7. **Data disk**: `langfuse-data` has `prevent_destroy`. Never change anything that would replace it without a restore plan.
8. **Strings in tf.json are templates**: shell `${VAR}` inside literals must be escaped (`_escapeTemplate`). Run `terraform validate` on synth output when changing embedded text.

## Checks

```bash
mise run check
```

Covers `dart analyze` / `dart test`, actionlint, shellcheck, `docker compose config`, and markdownlint. CI also runs `terraform plan` on PRs.

## Dependency Version Policy

- Pin versions in project files: `.tool-versions` for toolchains, `pubspec.yaml` for pub, image tags in `deploy/compose.yaml`.
- Dependabot covers pub, GitHub Actions, and Compose images. It does not read `.tool-versions`.
- Langfuse images are pinned to a patch release; majors (Langfuse v5, Postgres 18) need a migration plan in the PR description.

## Documentation Standards

- Blank lines around headings, lists, tables, and code blocks; language tags on code blocks.
- Update `README.md` and this file when the layout or a rule changes.
