# Bleat API Issue 64 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete issue 64's PostgreSQL challenge and installation-state foundation without implementing App Attest verification or JWT issuance.

**Architecture:** SeaORM owns PostgreSQL migrations and concrete repositories. Opaque challenge issuance stores only a digest and consumption uses conditional updates; installation counter changes use the same compare-and-update pattern. Axum receives a small application state containing the database-backed services and existing request limits.

**Tech Stack:** Rust 2024, Axum, Tokio, SeaORM, PostgreSQL, SHA-256, OS CSPRNG, Docker Compose.

---

### Task 1: PostgreSQL configuration and migrations

- [x] Add failing configuration and migration tests.
- [x] Add SeaORM PostgreSQL dependencies with Rustls through Cargo.
- [x] Implement typed database configuration, connection setup, and code-owned migrations.
- [x] Verify focused tests and commit.

### Task 2: Installation persistence

- [x] Add failing persistence, status-transition, and counter-race tests.
- [x] Implement the installation entity and concrete SeaORM repository.
- [x] Verify exactly one concurrent compare-and-update advances the counter.
- [x] Commit the focused change.

### Task 3: Opaque challenge lifecycle

- [x] Add failing issuance, digest, expiry, purpose, binding, replay, cleanup, and race tests.
- [x] Implement CSPRNG generation, base64url encoding, SHA-256 persistence, bounded cleanup, and typed consumption outcomes.
- [x] Verify exactly one concurrent consumption succeeds.
- [x] Commit the focused change.

### Task 4: HTTP integration and readiness

- [x] Add failing HTTP contract, database-readiness, privacy, and rate-bound tests.
- [x] Inject database-backed application state into the Axum router.
- [x] Implement both challenge endpoints and database-aware readiness while retaining enrollment/token placeholders.
- [x] Verify focused integration tests and commit.

### Task 5: Container and repository workflows

- [x] Add Dockerfile assertions and a failing disposable workflow smoke test.
- [x] Add a non-root multi-stage image, Compose PostgreSQL/API/test services, and cleanup-safe repository scripts.
- [x] Update `mise` tasks and current-behavior documentation.
- [x] Verify the image, disposable database suite, health/readiness, and challenge endpoints; commit.

### Task 6: Final review and delivery

- [x] Audit every issue 64 acceptance criterion against code, tests, container output, and documentation.
- [x] Run `mise run api:validate`, release-container smoke tests, OpenSSL dependency checks, `git diff --check`, secret/logging checks, and process-termination checks.
- [x] Review the complete scoped diff and fix all critical or important findings test-first.
- [x] Create local scoped commit(s), leaving the branch unpushed and GitHub unchanged.
