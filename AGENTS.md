# Agents Guide

Quick guide for contributors and AI agents working on `koborin-ai/langfuse`.

## Language Policy

- **Conversation**: Always communicate with the user in **Japanese**.
- **Code**: Write all code, comments, variable names, and commit messages in **English**.

## Mission

- The Langfuse deployment is decommissioned.
- The TerraDart root `LangfuseStack` declares no resources.

## Rules

1. **No local apply**: `terraform apply` runs only in `release-infra.yml`. Read-only inspection is fine.
2. **No keys**: GitHub Actions authenticates to GCP with Workload Identity Federation. Never add a service-account key.
3. **No secrets in git or state**: do not commit tokens, an app `.env`, or the owner email.
4. **State**: R2 bucket `koborin-ai-tfstate`, key `terraform/langfuse/terraform.tfstate`.
5. **Code as documentation**: the stack stays one explicit file (`infra/lib/langfuse_stack.dart`). Environment constants live in `infra/bin/synth.dart`. Synth reads only `CLOUDFLARE_ACCOUNT_ID`, and it uses that value only to build the R2 backend.
6. **Compose drift from upstream**: `deploy/compose.yaml` lists every difference from the upstream file in its header. Keep that list current when re-syncing.
7. **Empty stack**: the stack declares no resources. The next apply destroys every address still in state. Adding a resource block plans a create.
8. **Public repository**: never use `pull_request_target`; keep `permissions: {}` as the workflow default; apply/deploy jobs stay gated to `main`; never print `terraform plan` / `show` output with values (use `.github/scripts/tf-plan-summary.sh`); personal data goes through sensitive variables or secrets, not literals.
9. **No deploy or power workflow**: `deploy-app.yml` and `vm-power.yml` are removed. Do not add a workflow that starts the VM.
10. **Strings in tf.json are templates**: shell `${VAR}` and `%{` inside a literal must be escaped before synth writes the file. The stack embeds no scripts.

## Checks

```bash
mise run check
```

Covers `dart analyze` / `dart test`, actionlint, shellcheck, `docker compose config`, and markdownlint. CI also runs `terraform plan` on PRs.

## Dependency Version Policy

- Pin versions in project files: `.tool-versions` for toolchains, `pubspec.yaml` for pub, image tags in `deploy/compose.yaml`.
- `.github/dependabot.yml` is removed. A Compose image bump would ship `deploy/`. A pub bump would re-enter `release-infra`.
- Langfuse images are pinned to a patch release; majors (Langfuse v5, Postgres 18) need a migration plan in the PR description.

## Documentation Standards

- Blank lines around headings, lists, tables, and code blocks; language tags on code blocks.
- Update `README.md` and this file when the layout or a rule changes.
