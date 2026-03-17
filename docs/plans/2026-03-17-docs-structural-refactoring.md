# Docs Structural Refactoring — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the second pass of documentation refactoring — split multi-topic docs, relocate specs, and distribute fragile central file path tables.

**Architecture:** Three independent tasks that can be executed in parallel. Each produces a clean commit. No code changes — docs only.

**Prerequisite:** Commit `8509ae8` (first pass: analytics extraction, auth lane consolidation, date stripping, catalog trim, platformvision deprecation).

---

## Task 1: Split FIRESTORE_SCHEMA.md into schema + API reference

FIRESTORE_SCHEMA.md (1928 lines) serves two audiences: data modelers (schema) and API consumers (endpoint docs). Split into two focused docs.

**Files:**
- Create: `docs/API_REFERENCE.md`
- Modify: `docs/FIRESTORE_SCHEMA.md`
- Modify: `docs/README.md`

**What moves to API_REFERENCE.md:**
- "API Reference - HTTPS Endpoints" (lines 20-460) — all HTTPS endpoint docs
- "Streaming API - SSE Events" (lines 462-546) — SSE stream format, event types, tool display

**What stays in FIRESTORE_SCHEMA.md:**
- Everything from "Firestore Data Model (Current State)" onward — collections, indexes, security rules, query patterns, naming notes, mutations, self-healing, LLM usage, training analysis, catalog admin

- [ ] **Step 1:** Read `docs/FIRESTORE_SCHEMA.md` lines 1-546 (API + SSE sections)
- [ ] **Step 2:** Create `docs/API_REFERENCE.md` with the extracted API and SSE content. Add a header:
  ```markdown
  # API Reference

  > HTTPS endpoints and SSE streaming API for the Povver platform.
  > For auth lanes and middleware, see `docs/SECURITY.md`.
  > For Firestore data model, see `docs/FIRESTORE_SCHEMA.md`.
  ```
- [ ] **Step 3:** Edit `docs/FIRESTORE_SCHEMA.md` — remove lines 20-546 (API + SSE sections). Update the document header and ToC:
  ```markdown
  # Firestore Schema

  > Firestore data model, collections, indexes, security rules, and automatic mutations.
  > For API endpoints and SSE streaming, see `docs/API_REFERENCE.md`.
  ```
- [ ] **Step 4:** Update `docs/README.md` — add API_REFERENCE.md entry in Architecture Documentation, update FIRESTORE_SCHEMA.md description
- [ ] **Step 5:** Commit:
  ```bash
  git add docs/API_REFERENCE.md docs/FIRESTORE_SCHEMA.md docs/README.md
  git commit -m "docs: split API reference from Firestore schema"
  ```

---

## Task 2: Relocate FOCUS_MODE_WORKOUT_EXECUTION.md to specs/

This doc (2359 lines) is a product spec with implementation phases, acceptance criteria, and UI/UX requirements — not an architecture reference. Move it and trim the completed implementation status appendix.

**Files:**
- Move: `docs/FOCUS_MODE_WORKOUT_EXECUTION.md` → `docs/specs/FOCUS_MODE_WORKOUT_EXECUTION.md`
- Modify: `docs/README.md`

- [ ] **Step 1:** Create `docs/specs/` directory
- [ ] **Step 2:** `git mv docs/FOCUS_MODE_WORKOUT_EXECUTION.md docs/specs/FOCUS_MODE_WORKOUT_EXECUTION.md`
- [ ] **Step 3:** In the moved file, trim "Appendix A: Implementation Status" — all items marked complete can be removed. Keep only "A.3 Remaining Work" if any items are still open.
- [ ] **Step 4:** Update `docs/README.md` — move entry from Architecture to a "Specs" section with updated path
- [ ] **Step 5:** Search for any cross-references to the old path and update them:
  ```bash
  grep -r "FOCUS_MODE_WORKOUT_EXECUTION" docs/ --include="*.md"
  ```
- [ ] **Step 6:** Commit:
  ```bash
  git add docs/specs/ docs/README.md
  git commit -m "docs: relocate workout execution spec to docs/specs/"
  ```

---

## Task 3: Distribute file path table from SYSTEM_ARCHITECTURE.md

The central 40-path table in SYSTEM_ARCHITECTURE.md is useful but fragile — every refactor risks staleness. Module docs already have their own file maps. Move paths to where they'll be maintained alongside the code.

**Files:**
- Modify: `docs/SYSTEM_ARCHITECTURE.md`
- Modify: `docs/IOS_ARCHITECTURE.md` (verify its file map covers the iOS paths)
- Modify: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` (verify its directory structure covers the functions paths)
- Modify: `docs/SHELL_AGENT_ARCHITECTURE.md` (verify its file structure covers agent paths)

- [ ] **Step 1:** Read the file path table in `docs/SYSTEM_ARCHITECTURE.md` (lines 10-49) and categorize each path by module (iOS, Firebase Functions, Agent, Cross-cutting)
- [ ] **Step 2:** For each module doc, read its existing file map section and identify any paths from the central table that are missing
- [ ] **Step 3:** Add missing paths to the appropriate module doc's file map
- [ ] **Step 4:** Replace the central table in SYSTEM_ARCHITECTURE.md with a compact cross-reference:
  ```markdown
  ## File Path Reference

  Each module doc maintains its own file map. See:
  - **iOS**: `docs/IOS_ARCHITECTURE.md` → "File Map" section
  - **Firebase Functions**: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` → "Directory Structure" section
  - **Shell Agent**: `docs/SHELL_AGENT_ARCHITECTURE.md` → "File Structure" section
  - **Catalog Orchestrator**: `docs/CATALOG_ORCHESTRATOR_ARCHITECTURE.md` → "File Index" section

  **Cross-cutting paths** (not owned by a single module):

  | Component | Path | Purpose |
  |-----------|------|---------|
  | Shared Agent Utilities | `adk_agent/shared/` | Cross-agent usage tracking + pricing |
  | LLM Usage Query | `scripts/query_llm_usage.js` | Weekly cost aggregation |
  | Privacy Manifest | `Povver/Povver/PrivacyInfo.xcprivacy` | App Store privacy declarations |
  ```
- [ ] **Step 5:** Commit:
  ```bash
  git add docs/SYSTEM_ARCHITECTURE.md docs/IOS_ARCHITECTURE.md docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md docs/SHELL_AGENT_ARCHITECTURE.md
  git commit -m "docs: distribute file path table to module docs"
  ```
