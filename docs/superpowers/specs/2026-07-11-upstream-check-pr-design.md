# Design: Open a PR for upstream version bumps

## Problem

The `Check Upstream Releases` workflow fails at the `git push` step because the repository ruleset for `master` requires signed commits. The `github-actions[bot]` commit is unsigned, so the push is rejected with:

```text
remote: error: GH013: Repository rule violations found for refs/heads/master.
remote: - Commits must have verified signatures.
```

## Goal

Replace the direct push with a pull request. The PR must contain verified/signed commits so it can be merged into the protected `master` branch. The Docker image should still be built immediately, as it is today.

## Chosen approach

Use `peter-evans/create-pull-request@v8` with `sign-commits: true` and the default `GITHUB_TOKEN`. This signs commits as `github-actions[bot]` and satisfies the `required_signatures` rule without adding new secrets.

## Scope

Only `.github/workflows/upstream-check.yml` will be modified.

## Architecture

```text
on:
  schedule (daily)
  workflow_dispatch

jobs:
  check-upstream
    └── outputs: tools_changed, go_changed, new versions

  update-and-build (if versions changed)
    ├── Update Dockerfile version pins
    ├── Create Pull Request (signed commits)
    └── Trigger docker-build workflow
```

## Workflow changes

### 1. Permissions

The workflow needs these permissions at the top level:

- `contents: write` — to read the repo and create/update the PR branch
- `pull-requests: write` — to open/update the PR
- `actions: write` — to dispatch `docker-build.yml`
- `packages: write` — to allow `docker-build.yml` to push the image (existing)

### 2. Update Dockerfile

Keep the existing `Update Dockerfile version pins` step. It modifies `Dockerfile` in the working tree.

### 3. Create Pull Request

Replace the `Commit version bump` step with:

```yaml
- name: Create Pull Request
  uses: peter-evans/create-pull-request@v8
  with:
    token: ${{ github.token }}
    commit-message: |
      chore: bump upstream versions

      - amneziawg-tools: <version>
      - amneziawg-go: <version>
    title: "chore: bump upstream versions"
    body: |
      Automated version bump.

      - amneziawg-tools: <version>
      - amneziawg-go: <version>

      > Merge using **Squash** or **Rebase** to keep `master` linear.
    branch: chore/bump-upstream-versions
    delete-branch: true
    sign-commits: true
```

When `sign-commits: true` is used with `GITHUB_TOKEN`, the action signs commits as `github-actions[bot]`.

### 4. Trigger Docker build

Keep the existing `Trigger build workflow` step. It dispatches `docker-build.yml` with the new versions so the image is published without waiting for manual merge.

## Merge requirements

The repository ruleset enforces:

- `required_signatures` — satisfied by `sign-commits: true`
- `required_linear_history` — the PR must be merged with **Squash** or **Rebase**, not a merge commit

A note will be included in the PR body reminding maintainers to use Squash/Rebase.

## Error handling

- If no upstream change is detected, `update-and-build` is skipped via the existing `if:` condition.
- If the PR branch already exists, `create-pull-request` updates it instead of failing.
- If PR creation fails, the build step is not reached.

## Testing plan

1. Merge the workflow change.
2. Trigger `Check Upstream Releases` manually via `workflow_dispatch` (or wait for the scheduled run).
3. Verify a PR is opened and its commit shows as **Verified**.
4. Verify `docker-build.yml` is dispatched and completes successfully.
