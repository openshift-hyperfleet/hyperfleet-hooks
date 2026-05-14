# Commitlint Documentation

Complete guide for using hyperfleet-hooks commitlint in local development and Prow CI.

## Table of Contents

- [Overview](#overview)
- [Local Development](#local-development)
- [Prow CI Setup](#prow-ci-setup)
- [Cross-Component Usage](#cross-component-usage)
- [CLI Reference](#cli-reference)
- [Commit Message Standard](#commit-message-standard)
- [Troubleshooting](#troubleshooting)

## Overview

`hyperfleet-hooks commitlint` validates commit messages against the HyperFleet Commit Standard, based on [Conventional Commits](https://www.conventionalcommits.org/).

**Key Features**:
- ✅ Validates commit message format
- ✅ Validates PR titles in CI
- ✅ Works locally (pre-commit) and in Prow CI
- ✅ Zero configuration for other components

## Local Development

### Installation

1. Install pre-commit framework:
   ```bash
   pip install pre-commit
   ```

2. Add to `.pre-commit-config.yaml`:
   ```yaml
   repos:
     - repo: https://github.com/openshift-hyperfleet/hyperfleet-hooks
       rev: v0.1.0  # pin to a specific tag
       hooks:
         - id: hyperfleet-commitlint
   ```

3. Install the hook:
   ```bash
   pre-commit install --hook-type commit-msg
   ```

**Note**: Pre-commit will automatically clone the repository and build the binary. No manual installation of `hyperfleet-hooks` is needed.

### Manual Testing

```bash
# From file
hyperfleet-hooks commitlint .git/COMMIT_EDITMSG

# From stdin
echo "feat: add new feature" | hyperfleet-hooks commitlint
```

## Prow CI Setup

### Overview

`hyperfleet-hooks commitlint --pr` automatically:
1. Detects commit range from environment variables
2. Validates all commits in the PR
3. Validates PR title via GitHub API
4. Reports results

### PR Title Requirements

PR titles must include JIRA ticket: `<JIRA_PROJECT_ID>-<TICKET_NUM> - <type>: <subject>`

*Why?* For squash merges, PR title becomes the final commit message with traceability to JIRA.

Examples:
- ✅ `HYPERFLEET-123 - feat: add cluster validation`
- ✅ `SENTINEL-42 - fix: resolve timeout`
- ❌ `feat: add cluster validation` (missing JIRA)

### Configuration

Add a presubmit job to your component's Prow configuration:

```yaml
# ci-operator/jobs/openshift-hyperfleet/<component>/<component>-main-presubmits.yaml

presubmits:
  openshift-hyperfleet/<component>:
  - name: pull-ci-openshift-hyperfleet-<component>-main-validate-commits
    cluster: build05
    always_run: true
    decorate: true
    spec:
      containers:
      - name: validate
        image: quay.io/openshift-hyperfleet/hyperfleet-git-hooks:latest
        command:
        - hyperfleet-hooks
        - commitlint
        - --pr
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
```

### Environment Variables

Prow automatically provides these variables (no configuration needed):

| Variable | Example | Description |
|----------|---------|-------------|
| `PULL_REFS` | `main:abc123,456:def789` | Base and PR SHAs (most accurate) |
| `PULL_BASE_SHA` | `abc123...` | Base branch SHA (fallback) |
| `PULL_PULL_SHA` | `def789...` | PR head SHA (fallback) |
| `PULL_BASE_REF` | `main` | Target branch name |
| `PULL_NUMBER` | `123` | PR number |
| `REPO_OWNER` | `openshift-hyperfleet` | Repository owner |
| `REPO_NAME` | `hyperfleet-api` | Repository name |
| `GITHUB_TOKEN` | `ghp_...` | GitHub API token (optional) |

> **Note**: If `GITHUB_TOKEN` is not set, the tool uses the unauthenticated GitHub API (60 req/hr rate limit) and prints a warning to stderr. Set `GITHUB_TOKEN` in CI environments to avoid hitting rate limits.

**Commit range detection priority**:
1. `PULL_REFS` (most accurate)
2. `PULL_BASE_SHA` + `PULL_PULL_SHA`
3. `PULL_BASE_REF` + `HEAD` (local fallback)

### Trigger in PR

```bash
/test validate-commits    # Run validation job
/test all                 # Run all tests
/retest                   # Rerun failed tests
```

## Cross-Component Usage

All HyperFleet components use the same container image. **No installation required in component repositories.**

### Architecture

```text
┌─────────────────────────────────┐
│  hyperfleet-hooks Repository    │
│                                 │
│  1. Build Go binary             │
│  2. Build container image       │
│  3. Push to quay.io             │
└─────────────────────────────────┘
              │
              ▼
   quay.io/openshift-hyperfleet/hyperfleet-git-hooks:latest
              │
    ┌─────────┼─────────┬─────────┐
    ▼         ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│  API   │ │Sentinel│ │Adapter │ │ Broker │
└────────┘ └────────┘ └────────┘ └────────┘
  Use pre-built image, no dependencies!
```

Components just reference the image in Prow configuration. No dependencies to install.

### Updating to New Version

```bash
# In openshift/release repository
cd ci-operator/jobs/openshift-hyperfleet/
sed -i 's|hyperfleet-git-hooks:v1.0.0|hyperfleet-git-hooks:v1.1.0|g' */*-presubmits.yaml
git commit -m "ci: update hyperfleet-git-hooks to v1.1.0"
```

## CLI Reference

### Commands

```bash
# Validate single commit message
hyperfleet-hooks commitlint [file]

# Validate entire PR (commits + title)
hyperfleet-hooks commitlint --pr

# Show version
hyperfleet-hooks version
```

### Flags

| Flag | Description |
|------|-------------|
| `--pr` | Validate all commits and PR title (CI mode) |
| `-h, --help` | Show help |

### Exit Codes

- `0`: All validations passed
- `1`: Validation failed

## Commit Message Standard

### Format

```text
[<JIRA_PROJECT_ID>-<TICKET_NUM> - ]<type>: <subject>

[body]

[footer]
```

### Type (required)

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Code style (formatting)
- `refactor`: Code refactoring
- `perf`: Performance improvement
- `test`: Add/update tests
- `build`: Build system changes
- `ci`: CI configuration changes
- `chore`: Maintenance tasks
- `revert`: Revert previous commit

### Rules

- **JIRA ID**: Optional, format `<JIRA_PROJECT_ID>-<TICKET_NUM> - `
- **Type**: Required, one of the valid types (see above)
- **Subject**: Required, imperative mood, no period
- **Header Length**: `<type>: <subject>` must not exceed 72 characters (excluding JIRA prefix)
- **Body**: Optional, separated by blank line
- **Footer**: Optional, e.g., `BREAKING CHANGE:`, `Fixes #123`

### Examples

**Valid**:
```text
✅ feat: add user authentication
✅ HYPERFLEET-123 - fix: resolve memory leak
✅ SENTINEL-42 - docs: update API documentation
✅ refactor: simplify error handling
```

**Invalid**:
```text
❌ added new feature           # Missing type
❌ feat add feature             # Missing colon
❌ Feat: add feature            # Type must be lowercase
❌ feature: add feature         # Invalid type
```

## Troubleshooting

Common errors:
- `header must match format` → Add type: `feat:`, `fix:`, etc.
- `type must be one of` → Use valid type (feat, fix, docs, etc.)
- `header must not exceed 72 characters` → `<type>: <subject>` must be ≤ 72 chars (excluding JIRA prefix)
- `pr-title-requires-jira` → PR titles must start with `<JIRA_PROJECT_ID>-<TICKET_NUM> - `

Hook issues:
- Reinstall: `pre-commit install --hook-type commit-msg`
- Update version: `pre-commit autoupdate`

See [HyperFleet Commit Standard](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/commit-standard.md) for details.
