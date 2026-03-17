## UI Component Catalog and Contracts

This document enumerates the reusable, LLM-friendly components and their JSON schemas. Agents should construct UI by emitting validated JSON per schema; the iOS app renders cards and routes interactions through a central dispatcher.

### Design tokens and layout

- Spacing: `Space.*`
- Typography: `TypographyToken.*`
- Colors: `ColorsToken.*` (notably `Surface.card` for white cards)
- Motion/Elevation: `MotionToken.*`, `ShadowsToken.*`
- Layout: `LayoutToken.canvasColumns = 12`, `LayoutToken.contentMaxWidth = 860`

Grid rules
- Canvas uses a 12-track grid; card width spans:
  - `.oneThird` → 4 columns (~33%)
  - `.oneHalf` → 6 columns (50%)
  - `.full` → 12 columns (100%)

### Card base model (runtime)

- `CanvasCardModel` fields: `id, type, status, lane, title, subtitle, data, width, actions[], menuItems[], meta?`
- `CardAction { kind, label, style, iconSystemName?, payload? }`
- `CardMeta { context?, groupId?, pinned?, dismissible? }`

Central handler
- Environment value `cardActionHandler` dispatches any `CardAction` with the card context. Cards do not directly mutate state.

### Component list

- AgentPromptBar (chat home prompt)
- QuickActionCard
- Card primitives: `SurfaceCard`, `CardContainer`, `CardHeader`, `CardActionBar`, `CardOverflowMenu`
- Canvas grid: `CanvasGridView`
- PinnedRailView, UpNextRailView

Canvas cards
- AgentStreamCard — streaming steps (thinking/info/lookup/result)
- ClarifyQuestionsCard — structured questions (text/choice)
- RoutineOverviewCard — split/days/notes summary
- ListCardWithExpandableOptions — generic list (e.g., day workout)
- ProposalGroupHeader — group-level CTA (Accept all / Reject all)
- SmallContentCard, SuggestionCard, SessionPlanCard, ChatCard, VisualCard (existing)

Sheets & feedback
- RefineSheet, SwapSheet, EditSetSheet
- Banner, Toast, UndoToast

### JSON schemas (UI/Schemas)

- `card-base.schema.json` — shared: layout.width, meta, actions, menuItems
- `agent-stream.schema.json` — AgentStreamCard
- `clarify-questions.schema.json` — ClarifyQuestionsCard
- `routine-overview.schema.json` — RoutineOverviewCard
- `list-card.schema.json` — ListCardWithExpandableOptions
- `proposal-group.schema.json` — ProposalGroupHeader
- `inline-info.schema.json` — Small info blocks (explanations)
- `session-plan.schema.json`, `suggestion.schema.json`, `visualization.schema.json`, `text.schema.json`, `chat.schema.json`
- Action payload schemas: `edit-set.schema.json`, `swap-request.schema.json`

### Examples (UI/Schemas/examples)

- `plan_proposal.example.json` — header + overview + day list with actions
- `clarify-questions.example.json`
- `routine-overview.example.json`
- `edit-set.example.json`
- `swap-request.example.json`
- `agent-stream.example.json`
- `inline-info.example.json`
- `list-card.example.json`

### Authoring guidance for LLMs
### Staging smoke test (Canvas MVP)

Run through once on staging to validate E2E wiring:
- Start: app boots, login, navigate to Canvas tab (purpose `ad_hoc`).
- Bootstrap: `ConversationViewModel.start(userId,purpose)` calls `bootstrapCanvas` and subscribes.
- Propose: after sending an instruction (when wired), cards appear via Firestore; Up‑Next shows top 20 by priority.
- Accept: tap Accept/Reject on a card → `applyAction` with `expected_version` and idempotency; retry once on `STALE_VERSION`.
- Group actions: Accept all/Reject all sends `payload.group_id`.
- Undo: toast allows `UNDO` for supported actions.
- Telemetry: events stream logs `correlation_id` in console.

Definition of Done
- Canvas opens on live data (no demo seeding); subscriptions drive UI.
- Actions use `applyAction` with version/idempotency and map errors to banner/toast.
- Group actions and Undo work; Up‑Next ordering is respected.

1) Always include `layout.width` (default `full`).
2) Use `actions[]` for primary/secondary CTAs; overflow goes to `menuItems[]`.
3) Provide `meta.context` (e.g., `proposal`, `apply`, `active_workout`) and `meta.groupId` for grouped proposals.
4) Prefer concise titles and two-line subtitles; avoid paragraphs in lists.
5) Clarify first: use `clarify-questions` before proposing plans when user context is insufficient.
6) Proposal groups: emit a `groupHeader` followed by dependent cards with the same `groupId`.


