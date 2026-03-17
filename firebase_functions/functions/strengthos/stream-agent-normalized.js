/**
 * =============================================================================
 * stream-agent-normalized.js - SSE Proxy to Vertex AI Agent Engine
 * =============================================================================
 *
 * PURPOSE:
 * Firebase Function that proxies streaming requests to the Vertex AI Agent Engine.
 * Transforms raw ADK streaming events into normalized iOS-friendly StreamEvent format.
 * This is the ONLY entry point for real-time agent communication.
 *
 * ARCHITECTURE CONTEXT:
 * ┌─────────────────┐       ┌─────────────────────────────┐       ┌────────────────────┐
 * │ iOS App         │       │ stream-agent-normalized.js  │       │ Vertex AI          │
 * │                 │       │                             │       │ Agent Engine       │
 * │ DirectStreaming │──SSE─►│ 1. Auth with Firebase ID    │       │                    │
 * │ Service         │◄─────│ 2. Get GCP access token     │──────►│ Reasoning Engine   │
 * │                 │       │ 3. Create/reuse session     │       │ (agentId: 8723...)│
 * │ Consumes:       │       │ 4. Stream to :streamQuery   │◄──────│                    │
 * │  toolRunning    │       │ 5. Transform ADK → iOS      │       │ Returns raw ADK    │
 * │  toolComplete   │       │ 6. Emit normalized SSE      │       │ NDJSON stream      │
 * │  message        │       │ 7. Write workspace_entries  │       │                    │
 * │  agentResponse  │       └─────────────────────────────┘       └────────────────────┘
 * │  thinking       │
 * │  thought        │
 * │  status         │
 * │  error          │
 * │  done           │
 * └─────────────────┘
 *
 * VERTEX AI ENDPOINTS CALLED:
 * - :query (create_session) - Create new agent session
 * - :streamQuery (stream_query) - Stream agent response
 *
 * AGENT ID: 8723635205937561600 (Canvas Orchestrator)
 * PROJECT: myon-53d85
 * LOCATION: us-central1
 *
 * EVENT TRANSFORMATION (ADK → iOS):
 * | ADK Event         | iOS StreamEvent  | Content                      |
 * |-------------------|------------------|------------------------------|
 * | function_call     | toolRunning      | tool name + args             |
 * | function_response | toolComplete     | tool result + _display text  |
 * | text (part)       | text_delta       | partial text chunk           |
 * | text (commit)     | text_commit      | complete text segment        |
 * | (inferred)        | thinking         | "Analyzing..."               |
 * | (inferred)        | thought          | thought completion           |
 * | session created   | status           | session_id                   |
 * | stream end        | done             | {}                           |
 * | error             | error            | error message                |
 *
 * TOOL DISPLAY LABELS (TOOL_LABELS):
 * Maps tool names to human-readable labels for UI display.
 * These are the "Running" labels shown in ThoughtTrackView.
 * MUST be kept in sync with _display.running values in:
 * - adk_agent/canvas_orchestrator/app/agents/tools/coach_tools.py
 * - adk_agent/canvas_orchestrator/app/agents/tools/planner_tools.py
 *
 * _DISPLAY METADATA (Single Source of Truth):
 * Tools can emit _display metadata in their response:
 *   { _display: { running: "...", complete: "...", phase: "..." } }
 * If present, complete text is used as the toolComplete label.
 * See: adk_agent/canvas_orchestrator/app/libs/tools_common/response_helpers.py
 *
 * WORKSPACE ENTRIES:
 * Persists events to Firestore for debugging and replay:
 * - Path: users/{uid}/canvases/{canvasId}/workspace_entries
 * - Contains: event type, agent, correlation_id, timestamp
 *
 * CALLED BY:
 * - iOS: DirectStreamingService.streamQuery()
 *   → Povver/Povver/Services/DirectStreamingService.swift
 * - iOS: WorkoutCoachViewModel.send() (workout coaching mode, passes workoutId)
 *   → Povver/Povver/ViewModels/WorkoutCoachViewModel.swift
 *
 * RELATED FILES:
 * - ./config.js: VERTEX_AI_CONFIG (projectId, location)
 *
 * =============================================================================
 */

const { GoogleAuth } = require('google-auth-library');
const axios = require('axios');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');
const { VERTEX_AI_CONFIG } = require('./config');
const { isPremiumUser } = require('../utils/subscription-gate');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { agentLimiter } = require('../utils/rate-limiter');
const { v4: uuidv4 } = require('uuid');

// Cloud Run Agent Service URL (set via firebase functions .env)
const AGENT_SERVICE_URL = process.env.AGENT_SERVICE_URL;
// Note: AGENT_SERVICE_URL is optional during migration — if not set, falls back to Vertex AI

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

// ============================================================================
// GCP AUTH TOKEN CACHE (1hr TTL - tokens are valid for ~1hr)
// ============================================================================
let cachedGcpToken = null;
let tokenExpiresAt = 0;
const TOKEN_BUFFER_MS = 5 * 60 * 1000; // Refresh 5 min before expiry

async function getGcpAuthToken() {
  const now = Date.now();
  if (cachedGcpToken && now < tokenExpiresAt - TOKEN_BUFFER_MS) {
    logger.debug('[Auth] Using cached GCP token');
    return cachedGcpToken;
  }
  
  logger.info('[Auth] Fetching new GCP token...');
  const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
  cachedGcpToken = await auth.getAccessToken();
  tokenExpiresAt = now + (55 * 60 * 1000); // ~55 min (conservative)
  logger.info('[Auth] GCP token cached');
  return cachedGcpToken;
}

// Invalidate cached token on auth errors (401/403)
function invalidateTokenCache() {
  logger.info('[Auth] Invalidating cached GCP token');
  cachedGcpToken = null;
  tokenExpiresAt = 0;
}

// ============================================================================
// TOOL LABELS: SINGLE SOURCE OF TRUTH FOR RUNNING STATE
// These MUST match the _display.running values in the tool definitions.
// The tools emit _display.complete for the result, but we use these for tool_started.
// ============================================================================
const TOOL_LABELS = {
  // === COACH AGENT TOOLS (matches _display.running in coach_agent.py) ===
  tool_get_training_context: 'Loading training context',
  tool_get_analytics_features: 'Analyzing training data',
  tool_get_user_profile: 'Loading profile',
  tool_get_recent_workouts: 'Loading recent workouts',
  tool_get_user_exercises_by_muscle: 'Finding exercises',  // Dynamic in tool, generic here
  tool_search_exercises: 'Searching exercises',
  tool_get_exercise_details: 'Loading exercise details',
  
  // === PLANNER AGENT TOOLS (matches _display.running in planner_agent.py) ===
  tool_propose_workout: 'Creating workout plan',
  tool_propose_routine: 'Creating routine',
  tool_get_planning_context: 'Loading planning context',
  tool_get_next_workout: 'Finding next workout',
  tool_get_template: 'Loading template',
  tool_save_workout_as_template: 'Saving template',
  tool_create_routine: 'Creating routine',
  tool_manage_routine: 'Updating routine',
  tool_ask_user: 'Clarifying',
  tool_send_message: 'Responding',
  
  // ===== WITHOUT tool_ prefix (ADK may strip it) =====
  // Coach agent tools
  get_training_context: 'Loading training context',
  get_analytics_features: 'Analyzing training data',
  get_user_profile: 'Loading profile',
  get_recent_workouts: 'Loading recent workouts',
  get_user_exercises_by_muscle: 'Finding exercises',
  search_exercises: 'Searching exercises',
  get_exercise_details: 'Loading exercise details',
  // Planner agent tools
  propose_workout: 'Creating workout plan',
  propose_routine: 'Creating routine',
  get_planning_context: 'Loading planning context',
  get_next_workout: 'Finding next workout',
  get_template: 'Loading template',
  save_workout_as_template: 'Saving template',
  create_routine: 'Creating routine',
  manage_routine: 'Updating routine',
  ask_user: 'Clarifying',
  send_message: 'Responding',
  
  // === WORKOUT TOOLS (active workout coaching) ===
  tool_log_set: 'Logging set',
  tool_swap_exercise: 'Swapping exercise',
  tool_complete_workout: 'Completing workout',
  tool_get_workout_state: 'Refreshing workout state',
  log_set: 'Logging set',
  swap_exercise: 'Swapping exercise',
  complete_workout: 'Completing workout',
  get_workout_state: 'Refreshing workout state',

  // Legacy tools (v1.0 - deprecated)
  tool_set_context: 'Setting up',
  tool_record_user_info: 'Recording information',
  tool_create_workout_plan: 'Creating workout plan',
  tool_publish_workout_plan: 'Publishing plan',
  tool_emit_status: 'Logging',
  tool_set_canvas_context: 'Setting up',
  tool_fetch_profile: 'Reviewing profile',
  tool_fetch_recent_sessions: 'Checking history',
  tool_emit_agent_event: 'Logging',
  tool_request_clarification: 'Asking question',
  tool_format_workout_plan_cards: 'Formatting plan',
  tool_format_analysis_cards: 'Formatting analysis',
  tool_publish_cards: 'Publishing',
};

// EVENT_COMPAT removed in Phase 7 — iOS now uses tool_start/tool_end/clarification directly.

const TELEMETRY_LABELS = {
  'route.workout_planning': 'Routing to workout planner',
  'route.plan_workout': 'Routing to workout planner',
  'route.analysis': 'Routing to analysis agent',
  'plan_workout': 'Synthesizing workout plan',
  'analysis': 'Reviewing analysis task',
  'card.summary': 'Posting summary',
  'card.auto.plan_workout': 'Publishing workout cards',
  'card.auto.plan_workout.error': 'Workout card publish failed',
  'workout_proposed': 'Session plan published',
  'agent_propose': 'Cards posted to canvas',
};

const HIDDEN_TOOL_EVENTS = new Set([
  'transfer_to_agent',
  'tool_emit_agent_event',
  'tool_publish_cards',
  'tool_set_canvas_context',
]);

function shouldSuppressToolEvent(name = '') {
  if (!name) return false;
  if (HIDDEN_TOOL_EVENTS.has(name)) return true;
  if (name.startsWith('tool_emit_')) return true;
  return false;
}

function describeToolEvent(name, args = {}) {
  if (!name) return 'Working';
  if (name === 'transfer_to_agent' && args.agent_name) {
    return `Routing to ${args.agent_name}`;
  }
  if (name === 'tool_emit_agent_event' && args.event_type) {
    return `Telemetry: ${args.event_type}`;
  }
  
  // Try both with and without tool_ prefix
  const baseLabel = TOOL_LABELS[name] || TOOL_LABELS[`tool_${name}`] || name.replace(/_/g, ' ');
  
  // Add parameter details for key tools
  switch (name) {
    case 'tool_search_exercises': {
      const details = [];
      if (args.muscle_group) details.push(args.muscle_group);
      if (args.primary_muscle) details.push(args.primary_muscle);
      if (args.split) details.push(args.split);
      if (args.equipment) details.push(`with ${args.equipment}`);
      if (args.query) details.push(`"${args.query}"`);
      return details.length > 0 ? `${baseLabel}: ${details.join(', ')}` : baseLabel;
    }
    case 'tool_get_recent_workouts':
    case 'tool_fetch_recent_sessions': {
      const limit = args.limit || 5;
      return `${baseLabel} (last ${limit})`;
    }
    case 'tool_create_workout_plan': {
      const title = args.title || 'workout';
      const count = Array.isArray(args.exercises) ? args.exercises.length : 0;
      return count > 0 ? `${baseLabel}: "${title}" with ${count} exercises` : baseLabel;
    }
    case 'tool_ask_user':
    case 'tool_request_clarification': {
      return baseLabel;  // Don't expose the question in the tool event
    }
    default:
      return baseLabel;
  }
}

function describeToolResult(name, summary = '', args = {}) {
  const baseLabel = TOOL_LABELS[name] || TOOL_LABELS[`tool_${name}`] || name.replace(/_/g, ' ');
  
  // Parse summary for item counts
  const itemMatch = summary.match(/items?:\s*(\d+)/i);
  const itemCount = itemMatch ? parseInt(itemMatch[1], 10) : null;
  
  // Normalize tool name for switch (try with tool_ prefix)
  const normalizedName = name.startsWith('tool_') ? name : `tool_${name}`;
  
  switch (normalizedName) {
    case 'tool_search_exercises': {
      if (itemCount !== null) {
        const muscle = args.muscle_group || args.primary_muscle || '';
        return itemCount > 0 
          ? `Found ${itemCount} ${muscle} exercises`
          : `No ${muscle} exercises found`;
      }
      return 'Search complete';
    }
    case 'tool_get_recent_workouts':
    case 'tool_fetch_recent_sessions': {
      if (itemCount !== null) {
        return itemCount > 0 
          ? `Loaded ${itemCount} recent workouts`
          : 'No recent workouts';
      }
      return 'History loaded';
    }
    case 'tool_get_user_profile':
    case 'tool_fetch_profile':
      return 'Profile loaded';
    case 'tool_propose_workout':
      return 'Workout published';
    case 'tool_propose_routine':
      return 'Routine published';
    case 'tool_get_planning_context':
      return 'Context loaded';
    case 'tool_get_next_workout':
      return 'Found next workout';
    case 'tool_get_template':
      return 'Template loaded';
    case 'tool_save_workout_as_template':
      return 'Template saved';
    case 'tool_create_routine':
      return 'Routine created';
    case 'tool_manage_routine':
      return 'Routine updated';
    case 'tool_create_workout_plan':
      return 'Plan created';
    case 'tool_publish_workout_plan':
      return 'Plan published';
    // Analysis agent tools
    case 'tool_get_analytics_features':
      return 'Training data analyzed';
    case 'tool_get_user_exercises_by_muscle':
      return 'Exercises found';
    // Coach agent tools
    case 'tool_get_training_context':
      return 'Context loaded';
    case 'tool_get_exercise_details':
      return 'Exercise details loaded';
    // Workout tools
    case 'tool_log_set':
      return 'Set logged';
    case 'tool_swap_exercise':
      return 'Exercise swapped';
    case 'tool_complete_workout':
      return 'Workout completed';
    case 'tool_get_workout_state':
      return 'Workout state refreshed';
    default:
      return summary || 'Complete';
  }
}

function formatTelemetryEvent(evt) {
  if (!evt || typeof evt !== 'object') return null;
  const { type, payload = {} } = evt;
  const baseLabel = TELEMETRY_LABELS[type];
  if (!type && !baseLabel) return null;
  if (type === 'clarification.request') {
    return {
      type: 'clarification.request',
      agent: 'orchestrator',
      timestamp: Date.now() / 1000,
      content: payload,
    };
  }
  let text = baseLabel || type?.replace(/\./g, ' ') || 'Update';
  if (type === 'card.auto.plan_workout.error' && payload.error) {
    text = `${text}: ${payload.error}`;
  }
  if (type === 'plan_workout' && payload.session && payload.session.title) {
    text = `${text}: ${payload.session.title}`;
  }
  return {
    type: 'status',
    agent: 'orchestrator',
    timestamp: Date.now() / 1000,
    content: {
      text,
      status: text,
      telemetry_type: type,
      payload,
    },
    metadata: { telemetry_type: type },
  };
}

const WORKSPACE_EVENT_TYPES = new Set([
  'status',
  'thinking',
  'thought',
  'toolRunning',
  'toolComplete',
  'message',
  'agent_response',
  'agentResponse',
  'text_commit',
  'error',
  'done',
  'user_prompt',
  'artifact',
  'clarification.request',
  'pipeline',  // CoT visibility events (router, planner, critic, thinking)
]);

function sanitizeWorkspaceEvent(evt = {}) {
  const clean = {
    type: evt.type || 'unknown',
    agent: evt.agent || null,
    timestamp: typeof evt.timestamp === 'number' ? evt.timestamp : Date.now() / 1000,
  };
  if (evt.content) clean.content = evt.content;
  if (evt.metadata) clean.metadata = evt.metadata;
  return clean;
}

// Helper: SSE writer for NDJSON lines
function createSSE(res) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders?.();

  const write = (obj) => {
    try {
      res.write(`data: ${JSON.stringify(obj)}\n\n`);
    } catch (err) {
      // Ignore write errors after client disconnects
    }
  };

  const close = () => {
    try { res.end(); } catch (_) {}
  };

  return { write, close };
}

// Simple rolling hash for dedupe
function fingerprint(text) {
  const trimmed = (text || '').trim().toLowerCase();
  const sample = trimmed.slice(-128);
  let hash = 5381;
  for (let i = 0; i < sample.length; i++) {
    hash = ((hash << 5) + hash) + sample.charCodeAt(i);
    hash >>>= 0; // force uint32
  }
  return String(hash);
}

// Track event start times for duration calculation
const eventStartTimes = new Map();
// Track tool args for use in result description
const toolArgsCache = new Map();
// Track current active agent (updated on transfer_to_agent calls)
let currentActiveAgent = 'orchestrator';

// Transform ADK events to iOS-friendly StreamEvent format
function transformToIOSEvent(adkEvent) {
  const timestamp = Date.now() / 1000; // Convert to seconds
  const base = {
    type: 'unknown',
    agent: currentActiveAgent,  // Use tracked agent instead of hardcoded
    timestamp,
    metadata: {}
  };

  // === HANDLE PIPELINE EVENTS (CoT visibility) ===
  // Pipeline events expose the agent's internal reasoning chain
  if (adkEvent._pipeline) {
    const pipeline = adkEvent._pipeline;
    const pipelineType = pipeline.type || 'unknown';
    
    return {
      ...base,
      type: 'pipeline',
      content: {
        step: pipelineType,
        // Router fields
        lane: pipeline.lane || null,
        intent: pipeline.intent || null,
        signals: pipeline.signals || null,
        // Planner fields
        data_needed: pipeline.data_needed || null,
        rationale: pipeline.rationale || null,
        suggested_tools: pipeline.suggested_tools || null,
        // Thinking fields
        text: pipeline.text || null,
        // Critic fields
        passed: pipeline.passed !== undefined ? pipeline.passed : null,
        findings: pipeline.findings || null,
        errors: pipeline.errors || null,
      },
      metadata: {
        pipeline_type: pipelineType,
        timestamp: pipeline.timestamp || timestamp,
      }
    };
  }

  // Map ADK event types to iOS event types
  switch (adkEvent.type) {
    case 'tool_started': {
      const toolName = adkEvent.name || 'tool';
      const toolKey = `tool_${toolName}`;
      if (shouldSuppressToolEvent(toolName)) {
        eventStartTimes.delete(toolKey);
        toolArgsCache.delete(toolKey);
        return null;
      }
      // Track start time and args for duration/result description
      eventStartTimes.set(toolKey, timestamp);
      toolArgsCache.set(toolKey, adkEvent.args || {});
      
      return {
        ...base,
        type: 'tool_start',
        content: {
          tool: toolName,
          tool_name: toolName,
          args: adkEvent.args,
          text: describeToolEvent(toolName, adkEvent.args)
        },
        metadata: {
          start_time: timestamp
        }
      };
    }
    
    case 'tool_result': {
      const toolName = adkEvent.name || 'tool';
      const toolResultKey = `tool_${toolName}`;
      if (shouldSuppressToolEvent(toolName)) {
        eventStartTimes.delete(toolResultKey);
        toolArgsCache.delete(toolResultKey);
        return null;
      }
      // Calculate duration if we have start time
      const toolStartTime = eventStartTimes.get(toolResultKey);
      const cachedArgs = toolArgsCache.get(toolResultKey) || {};
      const metadata = toolStartTime ? { start_time: toolStartTime } : {};
      eventStartTimes.delete(toolResultKey);
      toolArgsCache.delete(toolResultKey);
      
      // === SINGLE SOURCE OF TRUTH: Use _display.complete if provided by tool ===
      // Fall back to describeToolResult for legacy tools without _display
      const resultText = adkEvent.displayText || describeToolResult(toolName, adkEvent.summary || '', cachedArgs);
      
      // Add phase to metadata if provided by tool
      if (adkEvent.phase) {
        metadata.phase = adkEvent.phase;
      }
      
      return {
        ...base,
        type: 'tool_end',
        content: {
          tool: toolName,
          tool_name: toolName,
          result: adkEvent.summary || 'Complete',
          text: resultText,
          phase: adkEvent.phase || null,
        },
        metadata
      };
    }
    
    case 'text_delta':
      return {
        ...base,
        type: 'message',
        content: {
          text: adkEvent.text || '',
          role: 'assistant',
          is_delta: true
        }
      };
    
    case 'text_commit':
      return {
        ...base,
        type: 'message',
        content: {
          text: adkEvent.text || '',
          role: 'assistant',
          is_commit: true
        }
      };
    
    case 'thinking':
      // Track thinking start time
      eventStartTimes.set('thinking', timestamp);
      
      // thinking/thought events mapped to status (no longer separate event types)
      return {
        ...base,
        type: 'status',
        content: {
          text: adkEvent.text || 'Analyzing...'
        },
        metadata: {
          start_time: timestamp
        }
      };

    case 'thought':
      eventStartTimes.delete('thinking');
      return {
        ...base,
        type: 'status',
        content: {
          text: adkEvent.text || 'Done thinking'
        }
      };
    
    case 'session':
      return {
        ...base,
        type: 'status',
        content: {
          text: 'Connected',
          session_id: adkEvent.sessionId
        }
      };
    
    case 'done':
      // Clear all tracked times
      eventStartTimes.clear();
      
      return {
        ...base,
        type: 'done',
        content: {}
      };
    
    case 'error':
      // Clear tracked times on error
      eventStartTimes.clear();

      return {
        ...base,
        type: 'error',
        content: {
          error: adkEvent.error || 'Unknown error',
          text: adkEvent.error || 'Unknown error'
        }
      };

    case 'artifact':
      return {
        ...base,
        type: 'artifact',
        content: {
          artifact_id: adkEvent.artifact_id || null,
          artifact_type: adkEvent.artifact_type || 'unknown',
          artifact_content: adkEvent.content || {},
          actions: adkEvent.actions || [],
          status: adkEvent.status || 'proposed',
        }
      };

    default:
      // Pass through other events as-is
      return {
        ...base,
        type: adkEvent.type,
        content: adkEvent
      };
  }
}

class TextNormalizer {
  constructor(policy = {}) {
    this.buffer = '';
    this.lastTail = '';
    this.seen = new Set();
    this.seq = 0;
    this.isFenceOpen = false;
    this.currentFenceLang = '';
    this.policy = {
      markdown_policy: {
        bullets: '-',
        max_bullets: 6,
        no_headers: true,
        ...policy.markdown_policy,
      },
    };
  }

  // Normalize bullets and strip headings
  preprocess(input) {
    if (!input) return '';
    let text = input
      .replace(/[\u2022\u2023]/g, '-') // •, ‣ → '-'
      .replace(/\r/g, '')
      .replace(/\t\*\s/g, '- ')
      .replace(/^\*\s/gm, '- ')
      .replace(/^•\s/gm, '- ')
      .replace(/^\-\s*/gm, '- ');

    // Collapse stacked hyphen bullets like "- - " → "- "
    text = text.replace(/^\s*[-•]+\s+/gm, '- ');

    // If a bullet appears inline as " - ", treat it as a list item boundary
    // Convert " ... - Something" to "\n- Something" when not inside code
    text = text.replace(/([^\n])\s-\s(?!-)/g, '$1\n- ');

    // Remove stray hyphen before punctuation ("- ." → ".")
    text = text.replace(/-\s*([\.,!\?])/g, '$1');

    // Ensure a space after sentence punctuation when followed by a letter (fixes "performance.Based")
    // Exclude digits after '.' to preserve decimal numbers like "67.2 kg"
    text = text.replace(/([\.!\?])([a-zA-Z])/g, (m, p1, p2) => `${p1} ${p2}`);

    // Drop trailing hyphens at end of lines introduced mid-stream ("working sets-\n" → "working sets\n")
    text = text.replace(/-\s*$/gm, '');

    // Collapse multiple spaces
    text = text.replace(/\s{2,}/g, ' ');

    if (this.policy.markdown_policy?.no_headers) {
      text = text
        .split('\n')
        .filter((ln) => !(ln.trim().startsWith('# ')
          || ln.trim().startsWith('## ')
          || ln.trim().startsWith('### ')))
        .join('\n');
    }
    return text;
  }

  // Decide safe commit boundary avoiding open code-fences
  computeCommitWindow(text, allowPartial) {
    if (allowPartial) return { commit: text, keep: '' };
    const delimiters = ['\n\n', '. ', '! ', '? ', '\n- ', '\n* ', '\n1. '];
    let cut = -1;
    let matched = '';
    for (const d of delimiters) {
      const idx = text.lastIndexOf(d);
      if (idx !== -1) { matched = d; cut = idx + d.length; break; }
    }
    const fenceCount = (text.match(/```/g) || []).length;
    const isFenceOpen = fenceCount % 2 === 1;
    if (isFenceOpen) return { commit: '', keep: text }; // never commit inside open fence
    // If boundary found is the start of a list item ("\n- ", "\n* ", "\n1. "),
    // commit BEFORE the delimiter so we don't flush a dangling bullet marker
    if (cut !== -1) {
      if (matched === '\n- ' || matched === '\n* ' || matched === '\n1. ') {
        const idx = text.lastIndexOf(matched);
        return { commit: text.slice(0, idx), keep: text.slice(idx) };
      }
      return { commit: text.slice(0, cut), keep: text.slice(cut) };
    }
    return { commit: '', keep: text };
  }

  dedupeTrailing(addition, minLen = 6) {
    const add = (addition || '').trim();
    if (!add) return '';
    const tail = this.lastTail || this.buffer.slice(-200);
    if (tail && (tail.endsWith(add) || tail.includes(add))) return '';
    const window = this.buffer.slice(-800);
    if (window.includes(add) && add.length >= minLen) return '';
    const fp = fingerprint(add);
    if (this.seen.has(fp)) return '';
    this.seen.add(fp);
    return addition;
  }

  nextSeq() { this.seq += 1; return this.seq; }
}

// ============================================================================
// CLOUD RUN AGENT SERVICE (Phase 3a — replaces Vertex AI when AGENT_SERVICE_URL is set)
// ============================================================================

async function callAgentService(userId, conversationId, message, correlationId, workoutId) {
  const auth = new GoogleAuth();
  const client = await auth.getIdTokenClient(AGENT_SERVICE_URL);
  const response = await client.request({
    url: `${AGENT_SERVICE_URL}/stream`,
    method: 'POST',
    data: {
      user_id: userId,
      conversation_id: conversationId,
      message,
      correlation_id: correlationId || uuidv4(),
      workout_id: workoutId || null,
    },
    responseType: 'stream',
    timeout: 180000,
  });
  return response.data;
}

function relayCloudRunStream(stream, sse, persistWorkspaceEntry, normalizer, userId, conversationId, correlationId) {
  return new Promise((resolve, reject) => {
    let partial = '';
    let accumulatedAgentText = '';

    stream.on('data', (chunk) => {
      partial += chunk.toString('utf8');
      const lines = partial.split('\n');
      partial = lines.pop();

      for (const rawLine of lines) {
        const trimmed = rawLine.trim();
        if (!trimmed) continue;

        // SSE format: "event: type\ndata: {...}\n\n" or "data: {...}\n\n"
        if (trimmed.startsWith('event:')) continue; // skip event type line, data follows
        if (!trimmed.startsWith('data:')) continue;

        const jsonStr = trimmed.slice(5).trim(); // remove "data: "
        if (!jsonStr) continue;

        try {
          const evt = JSON.parse(jsonStr);
          const eventType = evt.type || 'unknown';

          const translatedType = eventType;

          // Agent service now includes all fields at top level of data JSON
          // (type, text, tool, call_id, etc.) — no nested evt.data wrapper.

          // Accumulate agent text for conversation persistence
          if (eventType === 'message' && evt.text) {
            accumulatedAgentText += evt.text;
          }

          // Special handling for specific event types
          if (eventType === 'tool_start') {
            const name = evt.tool || 'tool';
            const label = TOOL_LABELS[name] || `Running ${name}`;
            sse.write({ type: 'tool_started', name, args: evt.args || {} });
          } else if (eventType === 'tool_end') {
            const name = evt.tool || 'tool';
            sse.write({ type: 'tool_result', name, summary: evt.result || '' });
          } else if (eventType === 'message') {
            const rawText = evt.text || '';
            const text = normalizer.preprocess ? normalizer.preprocess(rawText) : rawText;
            if (text) {
              sse.write({ type: 'text_delta', text });
            }
          } else if (eventType === 'artifact') {
            sse.write({ type: 'artifact', ...evt });
          } else if (eventType === 'status') {
            sse.write({ type: 'status', content: evt });
          } else if (eventType === 'heartbeat') {
            sse.write({ type: 'heartbeat' });
          } else if (eventType === 'done') {
            // Don't emit done here — handled by caller
          } else if (eventType === 'error') {
            sse.write({ type: 'error', error: evt });
          }

          // Persist to workspace_entries
          persistWorkspaceEntry({ type: translatedType, ...evt.data });

        } catch (parseErr) {
          logger.debug('[relayCloudRun] Failed to parse SSE line', { line: trimmed.slice(0, 200) });
        }
      }
    });

    stream.on('end', () => {
      // Persist accumulated agent response
      if (accumulatedAgentText) {
        const messagesRef = db
          .collection('users').doc(userId)
          .collection('conversations').doc(conversationId)
          .collection('messages');
        messagesRef.add({
          type: 'agent_response',
          content: accumulatedAgentText,
          correlation_id: correlationId || null,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        }).catch(err => logger.warn('[relayCloudRun] agent response persist failed', { error: String(err?.message || err) }));
      }
      resolve();
    });

    stream.on('error', (err) => {
      reject(err);
    });
  });
}

// ============================================================================
// CONVERSATION TITLE GENERATION (fire-and-forget after first exchange)
// Uses Gemini 2.0 Flash to produce a short 3-6 word title from the user message.
// Only runs once per conversation (skips if title already set).
// ============================================================================
async function generateConversationTitle(userId, conversationId, userMessage) {
  // Check conversations first (primary), fallback to canvases
  let existingDoc = await db.collection('users').doc(userId)
    .collection('conversations').doc(conversationId).get();
  if (!existingDoc.exists) {
    existingDoc = await db.collection('users').doc(userId)
      .collection('canvases').doc(conversationId).get();
  }
  if (existingDoc.exists && existingDoc.data()?.title) return;

  const token = await getGcpAuthToken();
  const projectId = VERTEX_AI_CONFIG.projectId;
  const location = VERTEX_AI_CONFIG.location;
  const url = `https://${location}-aiplatform.googleapis.com/v1/projects/${projectId}/locations/${location}/publishers/google/models/gemini-2.0-flash:generateContent`;

  // Truncate to 200 chars — sufficient for title inference, limits token waste and prompt injection surface
  const messageSample = userMessage.length > 200 ? userMessage.slice(0, 200) : userMessage;

  const resp = await axios.post(url, {
    contents: [{ role: 'user', parts: [{ text: `Generate a short 3-6 word title summarizing this fitness coaching conversation. Return only the title, no quotes or punctuation. Examples: Push Pull Legs Routine, Weekly Progress Analysis, Upper Body Workout Plan. User message: ${messageSample}` }] }],
    generationConfig: { temperature: 0.3, maxOutputTokens: 20 }
  }, { headers: { Authorization: `Bearer ${token}` }, timeout: 5000 });

  const title = resp.data?.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
  if (!title) return;

  const batch = db.batch();
  if (existingDoc.exists && existingDoc.ref.path.includes('/canvases/')) {
    batch.update(db.collection('users').doc(userId).collection('canvases').doc(conversationId), { title });
  }
  batch.set(db.collection('users').doc(userId).collection('conversations').doc(conversationId), { title }, { merge: true });
  await batch.commit();

  logger.info('[streamAgentNormalized] Generated conversation title', { conversationId, title });
}

async function streamAgentNormalizedHandler(req, res) {
  // CORS preflight handled by outer middleware when wrapped
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method Not Allowed' });
    return;
  }

  logger.info('[streamAgentNormalized] Handler invoked', { 
    body: req.body, 
    method: req.method,
    headers: { authorization: req.headers.authorization ? 'present' : 'missing' }
  });

  const sseRaw = createSSE(res);
  const normalizer = new TextNormalizer({ markdown_policy: req.body?.markdown_policy });
  const workspaceWrites = [];
  let persistWorkspaceEntry = () => {};

  const enqueueWorkspaceEntry = (ref, correlationId) => (event) => {
    if (!event || !WORKSPACE_EVENT_TYPES.has(event.type)) return;
    const record = {
      entry: sanitizeWorkspaceEvent(event),
      type: event.type,
      agent: event.agent || null,
      correlation_id: correlationId || null,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    };
    workspaceWrites.push(
      ref.add(record).catch((err) => {
        logger.warn('[streamAgentNormalized] workspace entry write failed', { error: String(err?.message || err) });
      })
    );
  };

  // Wrap SSE writer to transform ADK events to iOS StreamEvent format
  const sse = {
    write: (adkEvent) => {
      const iosEvent = transformToIOSEvent(adkEvent);
      if (!iosEvent) return;
      logger.debug('[streamAgentNormalized] Emitting event', { type: iosEvent.type });
      sseRaw.write(iosEvent);
      persistWorkspaceEntry(iosEvent);
    },
    close: () => sseRaw.close()
  };

  // Emit initial status
  sse.write({ type: 'status', content: { text: 'Connecting...' } });
  logger.info('[streamAgentNormalized] Emitted initial status');

  // Heartbeat every ~2500ms - send as status events
  const hb = setInterval(() => {
    sse.write({ type: 'heartbeat' });
  }, 2500);

  const finalizeWorkspaceWrites = () => Promise.allSettled(workspaceWrites).catch(() => {});
  let clientDisconnected = false;

  const done = (ok = true, err) => {
    clearInterval(hb);
    if (!clientDisconnected) {
      if (err) {
        sse.write({ type: 'error', error: String(err.message || err) });
      }
      sse.write({ type: 'done' });
    }
    finalizeWorkspaceWrites().finally(() => sse.close());
  };

  // Clean up on client disconnect — prevents zombie connections from exhausting maxInstances
  req.on('close', () => {
    if (!clientDisconnected) {
      clientDisconnected = true;
      clearInterval(hb);
      logger.info('[streamAgentNormalized] client_disconnected', { userId: 'pending' });
    }
  });

  try {
    // Dual auth: Bearer lane → req.auth.uid, API key lane → X-User-Id header or body
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      sse.write({
        type: 'error',
        error: {
          code: 'UNAUTHORIZED',
          message: 'Authentication required'
        }
      });
      done(false);
      return;
    }

    // Rate limit: 120 requests/hour per user (Vertex AI costs real money)
    if (!agentLimiter.check(userId)) {
      sse.write({
        type: 'error',
        error: {
          code: 'RATE_LIMITED',
          message: 'Too many requests. Please wait before sending another message.'
        }
      });
      done(false);
      return;
    }

    // Premium gate: Check if user has premium access
    const hasPremium = await isPremiumUser(userId);
    if (!hasPremium) {
      sse.write({
        type: 'error',
        error: {
          code: 'PREMIUM_REQUIRED',
          message: 'Premium subscription required for AI coaching'
        }
      });
      done(false); // no error arg — structured error already sent above
      return;
    }

    const message = req.body?.message || '';

    // Guard against cost abuse via oversized messages (10KB ≈ ~3000 tokens)
    if (message.length > 10000) {
      sse.write({ type: 'error', error: { code: 'INVALID_ARGUMENT', message: 'Message too long (max 10KB)' } });
      done(false);
      return;
    }

    // Accept both conversationId (new) and canvasId (legacy) during migration
    const conversationId = req.body?.conversationId || req.body?.canvasId;
    const correlationId = req.body?.correlationId || null;
    const workoutId = req.body?.workoutId || null;
    const streamStartTime = Date.now();

    if (!conversationId) {
      sse.write({ type: 'error', error: 'conversationId is required' });
      done(false, new Error('conversationId is required'));
      return;
    }

    // Messages collection for conversation history persistence
    const messagesRef = db
      .collection('users')
      .doc(userId)
      .collection('conversations')
      .doc(conversationId)
      .collection('messages');

    // Artifacts collection for proposed artifacts
    const artifactsRef = db
      .collection('users')
      .doc(userId)
      .collection('conversations')
      .doc(conversationId)
      .collection('artifacts');

    // Persist user's message
    messagesRef.add({
      type: 'user_prompt',
      content: message,
      correlation_id: correlationId || null,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    }).catch(err => logger.warn('[streamAgentNormalized] user message persist failed', { error: String(err?.message || err) }));

    // Legacy workspace_entries persistence (kept during migration)
    const workspaceRef = db
      .collection('users')
      .doc(userId)
      .collection('canvases')
      .doc(conversationId)
      .collection('workspace_entries');
    persistWorkspaceEntry = enqueueWorkspaceEntry(workspaceRef, correlationId);

    // Persist user prompt as workspace entry
    // (client can't write to workspace_entries — blocked by security rules)
    workspaceRef.add({
      entry: {
        type: 'user_prompt',
        agent: userId,
        content: { text: message, correlation_id: correlationId },
        timestamp: Date.now() / 1000,
        metadata: { source: 'server' },
      },
      type: 'user_prompt',
      agent: userId,
      correlation_id: correlationId || null,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    }).catch(err => logger.warn('[streamAgentNormalized] user prompt workspace entry failed', { error: String(err?.message || err) }));

    // Update conversation metadata for recent-chats listing
    // (client can't update canvas doc — blocked by security rules)
    const metadataUpdate = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastMessage: (message || '').slice(0, 100),
      status: 'active',
    };
    // Write to conversations (primary — iOS reads this)
    db.collection('users').doc(userId).collection('conversations').doc(conversationId)
      .set(metadataUpdate, { merge: true })
      .catch(err => logger.warn('[streamAgentNormalized] conversation metadata update failed', { error: String(err?.message || err) }));
    // Write to canvases (legacy — remove after full migration)
    db.collection('users').doc(userId).collection('canvases').doc(conversationId)
      .set(metadataUpdate, { merge: true })
      .catch(err => logger.warn('[streamAgentNormalized] canvas metadata update failed', { error: String(err?.message || err) }));

    // === CLOUD RUN AGENT SERVICE (Phase 3a) ===
    if (AGENT_SERVICE_URL) {
      logger.info('[streamAgentNormalized] Using Cloud Run agent service', { url: AGENT_SERVICE_URL });

      try {
        const agentStream = await callAgentService(userId, conversationId, message, correlationId, workoutId);
        await relayCloudRunStream(agentStream, sse, persistWorkspaceEntry, normalizer, userId, conversationId, correlationId);
        done(true);
      } catch (err) {
        logger.error('[streamAgentNormalized] Cloud Run agent error', { error: err.message, userId });
        sse.write({ type: 'error', error: { code: 'UPSTREAM_ERROR', message: err.message } });
        done(false);
      }
      return;
    }

    // === LEGACY: Vertex AI Agent Engine (removed after Phase 3a migration) ===
    // Canvas Orchestrator agent ID
    const agentId = '8723635205937561600';
    const projectId = VERTEX_AI_CONFIG.projectId;
    const location = VERTEX_AI_CONFIG.location;

    // Auth to Vertex (uses cached token)
    logger.info('[streamAgentNormalized] Getting Vertex AI auth token...');
    const token = await getGcpAuthToken();
    logger.info('[streamAgentNormalized] Got Vertex AI auth token');

    // Sessions eliminated (Phase 3c) — Vertex AI sessions are ephemeral per-request now.
    // The Cloud Run path (above) is the primary path; this legacy Vertex AI path
    // creates a throwaway session per request when AGENT_SERVICE_URL is not set.
    let sessionToUse = null;
    {
      logger.info('[streamAgentNormalized] Creating ephemeral session...');
      const createUrl = `https://${location}-aiplatform.googleapis.com/v1/projects/${projectId}/locations/${location}/reasoningEngines/${agentId}:query`;
      const createResp = await axios.post(createUrl, {
        class_method: 'create_session',
        input: { user_id: userId, state: { 'user:id': userId } },
      }, { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
      sessionToUse = createResp.data?.output?.id || createResp.data?.output?.session_id || createResp.data?.id;
      logger.info('[streamAgentNormalized] Created ephemeral session', { sessionId: sessionToUse });
    }

    const url = `https://${location}-aiplatform.googleapis.com/v1/projects/${projectId}/locations/${location}/reasoningEngines/${agentId}:streamQuery`;
    
    // Prepend context hint with conversation_id, user_id, today's date, and optional workout_id
    const todayISO = new Date().toISOString().split('T')[0]; // YYYY-MM-DD in UTC
    const contextHint = `(context: conversation_id=${conversationId} user_id=${userId} corr=${correlationId || 'none'} workout_id=${workoutId || 'none'} today=${todayISO})`;
    const finalMessage = message ? `${contextHint}\n${message}` : contextHint;
    
    const payload = {
      class_method: 'stream_query',
      input: { user_id: userId, session_id: sessionToUse, message: finalMessage },
    };

    logger.info('[streamAgentNormalized] Sending stream request to Vertex AI', { 
      agentId, 
      sessionId: sessionToUse,
      messageLength: finalMessage.length,
      url,
    });

    // Request as a stream
    let response;
    try {
      response = await axios({
        method: 'post',
        url,
        data: payload,
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        responseType: 'stream',
        timeout: 180000,  // 3 min — Flash may think + call tools + respond
        maxContentLength: Infinity,
        maxBodyLength: Infinity,
        validateStatus: (status) => status >= 200 && status < 500,
      });
    } catch (axiosErr) {
      logger.error('[streamAgentNormalized] Axios request failed', { 
        error: String(axiosErr?.message || axiosErr),
        response: axiosErr?.response?.data ? String(axiosErr.response.data).slice(0, 500) : null,
        status: axiosErr?.response?.status,
      });
      throw axiosErr;
    }
    
    logger.info('[streamAgentNormalized] Got response from Vertex AI', { 
      status: response.status,
      headers: response.headers ? Object.keys(response.headers) : null,
    });
    
    // Check for non-200 status
    if (response.status >= 400) {
      const errorBody = await new Promise((resolve) => {
        let data = '';
        response.data.on('data', (chunk) => { data += chunk.toString(); });
        response.data.on('end', () => { resolve(data); });
        response.data.on('error', () => { resolve(data); });
      });
      logger.error('[streamAgentNormalized] Vertex AI returned error', { status: response.status, body: errorBody.slice(0, 1000) });
      
      // Invalidate token cache on auth errors (401/403)
      if (response.status === 401 || response.status === 403) {
        invalidateTokenCache();
        sse.write({ type: 'error', error: 'Authentication failed. Please try again.', text: 'Authentication failed. Please try again.' });
        done(false, new Error(`Vertex AI returned ${response.status}`));
        return;
      }
      
      sse.write({ type: 'error', error: `Vertex AI error: ${response.status} - ${errorBody.slice(0, 200)}` });
      done(false, new Error(`Vertex AI returned ${response.status}`));
      return;
    }

    // Line-by-line reader with state tracking
    let partial = '';
    let isCurrentlyThinking = false;
    let hasEmittedThinkingEvent = false;
    let lineCount = 0;
    let dataChunkCount = 0;
    let artifactCount = 0;
    let accumulatedAgentText = ''; // Full agent text for conversation persistence
    
    // === RESET AGENT STATE FOR NEW STREAM ===
    // Reset to orchestrator at start of each request
    currentActiveAgent = 'orchestrator';
    
    // === EMIT INITIAL THINKING EVENT IMMEDIATELY ===
    // This ensures the UI shows the agent is working right away
    sse.write({ type: 'thinking', text: 'Analyzing...' });
    isCurrentlyThinking = true;
    hasEmittedThinkingEvent = true;
    
    response.data.on('data', (chunk) => {
      dataChunkCount++;
      logger.debug('[streamAgentNormalized] Received data chunk', { chunkNum: dataChunkCount, length: chunk.length });
      partial += chunk.toString('utf8');
      const lines = partial.split('\n');
      partial = lines.pop();
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const evt = JSON.parse(trimmed);

          // === HANDLE PIPELINE EVENTS FIRST (CoT visibility) ===
          // These are top-level events from _create_pipeline_event() in agent_engine_app.py
          if (evt._pipeline) {
            logger.debug('[streamAgentNormalized] Pipeline event received', { 
              type: evt._pipeline.type,
              intent: evt._pipeline.intent 
            });
            sse.write(evt);  // transformToIOSEvent handles _pipeline
            continue;
          }

          const role = evt?.content?.role || evt?.role || 'model';
          const parts = (evt?.content?.parts || []);
          const messageId = evt?.id || evt?.invocationId || null;

          // Map function calls/responses to tool events
          for (const p of parts) {
            if (p.function_call) {
              // If we were thinking and now calling a tool, emit thought completion
              if (isCurrentlyThinking && hasEmittedThinkingEvent) {
                sse.write({ type: 'thought', text: '' });
                isCurrentlyThinking = false;
                hasEmittedThinkingEvent = false;
              }
              
              const name = p.function_call.name || 'tool';
              const args = p.function_call.args || {};
              
              // === TRACK AGENT ROUTING: Update current agent on transfer ===
              if (name === 'transfer_to_agent' && args.agent_name) {
                const agentName = args.agent_name.toLowerCase();
                // Map ADK agent names to display names
                if (agentName.includes('coach')) {
                  currentActiveAgent = 'coach';
                } else if (agentName.includes('planner')) {
                  currentActiveAgent = 'planner';
                } else if (agentName.includes('copilot')) {
                  currentActiveAgent = 'copilot';
                } else {
                  currentActiveAgent = agentName;
                }
                logger.info('[streamAgentNormalized] Agent transfer detected', { 
                  targetAgent: currentActiveAgent,
                  rawAgentName: args.agent_name 
                });
              }
              
              sse.write({ type: 'tool_started', name, args });

              // === TOOL TRACING: Log tool invocation for debugging ===
              logger.info('[toolCall]', {
                correlation_id: correlationId || null,
                user_id: userId,
                tool: name,
                args_preview: JSON.stringify(args).slice(0, 1000),
                session_id: sessionToUse,
              });
            }
            if (p.function_response) {
              const name = p.function_response.name || 'tool';
              const resp = p.function_response.response;
              let summary = '';
              let parsedResponse = null;
              let displayText = null;
              let phase = null;
              
              try {
                parsedResponse = typeof resp === 'string' ? JSON.parse(resp) : resp;
                
                // === NEW: Extract _display metadata from tool result (single source of truth) ===
                if (parsedResponse && parsedResponse._display) {
                  const display = parsedResponse._display;
                  displayText = display.complete || null;
                  phase = display.phase || null;
                  logger.debug('[streamAgentNormalized] Found _display metadata', { 
                    tool: name, 
                    displayText, 
                    phase 
                  });
                }
                
                // Fallback: Handle various response formats for legacy tools without _display
                if (!displayText) {
                  if (Array.isArray(parsedResponse)) {
                    summary = `items: ${parsedResponse.length}`;
                  } else if (parsedResponse && typeof parsedResponse === 'object') {
                    if (Array.isArray(parsedResponse.data)) summary = `items: ${parsedResponse.data.length}`;
                    else if (Array.isArray(parsedResponse.items)) summary = `items: ${parsedResponse.items.length}`;
                    else if (Array.isArray(parsedResponse.sessions)) summary = `sessions: ${parsedResponse.sessions.length}`;
                    else if (Array.isArray(parsedResponse.templates)) summary = `templates: ${parsedResponse.templates.length}`;
                    else if (Array.isArray(parsedResponse.workouts)) summary = `workouts: ${parsedResponse.workouts.length}`;
                    else if (Array.isArray(parsedResponse.exercises)) summary = `items: ${parsedResponse.exercises.length}`;
                  }
                }
              } catch (_) {}
              
              // Pass displayText and phase to tool_result so transformToIOSEvent can use them
              sse.write({ type: 'tool_result', name, summary, displayText, phase });

              // === TOOL TRACING: Log tool result for debugging ===
              logger.info('[toolResult]', {
                correlation_id: correlationId || null,
                user_id: userId,
                tool: name,
                summary: summary || null,
                result_preview: parsedResponse
                  ? JSON.stringify(parsedResponse).slice(0, 1000)
                  : null,
                display_text: displayText || null,
                phase: phase || null,
              });

              // === ARTIFACT DETECTION ===
              // If tool response contains artifact_type, emit as artifact SSE event
              // and persist to Firestore for reload + action handling
              if (parsedResponse && parsedResponse.artifact_type) {
                artifactCount++;
                logger.info('[streamAgentNormalized] Artifact detected', {
                  tool: name,
                  artifact_type: parsedResponse.artifact_type,
                });

                // Pre-generate Firestore artifact ID so iOS can reference it for actions
                const artifactDocRef = artifactsRef.doc();

                // Emit artifact to iOS IMMEDIATELY via SSE (before async Firestore write)
                // Uses sse.write() to route through transformToIOSEvent for proper iOS format
                sse.write({
                  type: 'artifact',
                  artifact_id: artifactDocRef.id,
                  artifact_type: parsedResponse.artifact_type,
                  content: parsedResponse.content || {},
                  actions: parsedResponse.actions || [],
                  status: 'proposed',
                });

                // Persist artifact to Firestore async (don't block SSE stream)
                const artifactContent = parsedResponse.content || {};
                const MAX_ARTIFACT_SIZE = 50 * 1024; // 50KB
                const contentStr = JSON.stringify(artifactContent);
                if (contentStr.length > MAX_ARTIFACT_SIZE) {
                  logger.warn('[streamAgentNormalized] artifact_content_too_large', {
                    artifact_type: parsedResponse.artifact_type,
                    size: contentStr.length,
                    userId,
                  });
                  // Skip persistence only — artifact was already sent to client via SSE
                  // continue (not return) to keep processing remaining parts in this chunk
                  continue;
                }

                const artifactData = {
                  type: parsedResponse.artifact_type,
                  content: artifactContent,
                  actions: parsedResponse.actions || [],
                  status: 'proposed',
                  correlation_id: correlationId,
                  created_at: admin.firestore.FieldValue.serverTimestamp(),
                };

                artifactDocRef.set(artifactData)
                  .then(() => {
                    // Persist a message reference for conversation history
                    messagesRef.add({
                      type: 'artifact',
                      artifact_type: parsedResponse.artifact_type,
                      artifact_id: artifactDocRef.id,
                      correlation_id: correlationId || null,
                      created_at: admin.firestore.FieldValue.serverTimestamp(),
                    }).catch(err => logger.warn('[streamAgentNormalized] artifact message ref failed', { error: String(err?.message || err) }));
                  })
                  .catch(err => {
                    logger.warn('[streamAgentNormalized] artifact persist failed', { error: String(err?.message || err) });
                  });
              }

              if (parsedResponse && Array.isArray(parsedResponse.events)) {
                for (const evt of parsedResponse.events) {
                  if (evt && typeof evt === 'object') {
                    const formatted = formatTelemetryEvent(evt);
                    sse.write(formatted || evt);
                  }
                }
              }
              
              // After tool completes, agent is thinking about next step
              if (!isCurrentlyThinking) {
                sse.write({ type: 'thinking', text: 'Analyzing...' });
                isCurrentlyThinking = true;
                hasEmittedThinkingEvent = true;
              }
            }
          }

          // Text parts normalization with list/code detection
          for (const p of parts) {
            if (typeof p.text === 'string' && p.text) {
              // If we were thinking and now have text response, emit thought completion
              if (isCurrentlyThinking && hasEmittedThinkingEvent) {
                sse.write({ type: 'thought', text: '' });
                isCurrentlyThinking = false;
                hasEmittedThinkingEvent = false;
              }
              
              const incoming = normalizer.preprocess(p.text);
              const candidate = normalizer.dedupeTrailing(incoming);
              if (!candidate) continue;

              // Detect code fence transitions
              const fenceMatches = candidate.match(/```[a-zA-Z0-9_-]*/g) || [];
              let remainder = candidate;
              for (const match of fenceMatches) {
                const idx = remainder.indexOf(match);
                const before = remainder.slice(0, idx);
                if (before) {
                  normalizer.buffer += before;
                  accumulatedAgentText += before;
                  sse.write({ type: 'text_delta', text: before });
                }
                // Toggle fence state
                if (!normalizer.isFenceOpen) {
                  normalizer.isFenceOpen = true;
                  normalizer.currentFenceLang = match.replace('```', '') || '';
                  // Code blocks aren't mapped to iOS events yet, skip for now
                } else {
                  normalizer.isFenceOpen = false;
                  normalizer.currentFenceLang = '';
                }
                remainder = remainder.slice(idx + match.length);
              }
              if (remainder) {
                // Skip list item detection for simplicity
                normalizer.buffer += remainder;
                accumulatedAgentText += remainder;
                sse.write({ type: 'text_delta', text: remainder });
              }

              // Emit commit if safe
              const { commit, keep } = normalizer.computeCommitWindow(normalizer.buffer, false);
              if (commit) {
                // Coalesce tiny trailing commits that lack terminal punctuation
                const trimmed = commit.trim();
                const endsWell = /[\.!\?]$/.test(trimmed);
                if (trimmed.length < 40 && !endsWell) {
                  // keep everything for next pass
                } else {
                  sse.write({ type: 'text_commit', text: commit });
                  normalizer.buffer = keep;
                  normalizer.lastTail = (commit + keep).slice(-200);
                }
              }
            }
          }
        } catch (e) {
          // non-JSON line, ignore
        }
      }
    });

    response.data.on('end', async () => {
      logger.info('[streamAgentNormalized] Vertex AI stream ended', { 
        dataChunks: dataChunkCount, 
        bufferLength: normalizer.buffer.length,
        sessionId: sessionToUse
      });
      
      // Flush remaining buffer
      const pre = normalizer.preprocess(normalizer.buffer);
      if (pre) {
        sse.write({ type: 'text_commit', text: pre });
      }

      // Persist agent response to conversation messages for reload
      if (accumulatedAgentText.trim()) {
        messagesRef.add({
          type: 'agentResponse',
          content: accumulatedAgentText.trim(),
          correlation_id: correlationId || null,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        }).catch(err => logger.warn('[streamAgentNormalized] agent response persist failed', { error: String(err?.message || err) }));
      }

      // Generate conversation title (fire-and-forget, only on first exchange)
      // Skip on failed/empty streams — no point titling a broken conversation
      if (message && dataChunkCount > 0) {
        generateConversationTitle(userId, conversationId, message)
          .catch(err => logger.warn('[streamAgentNormalized] title generation failed', { error: String(err?.message || err) }));
      }

      // If no data chunks received, something went wrong
      if (dataChunkCount === 0) {
        logger.warn('[streamAgentNormalized] Stream ended with NO data', { sessionId: sessionToUse });
        sse.write({ type: 'error', error: 'No response received. Please try again.' });
      }

      logger.info('stream_completed', {
        event: 'stream_completed',
        success: dataChunkCount > 0,
        user_id: userId,
        conversation_id: conversationId,
        latency_ms: Date.now() - streamStartTime,
        had_artifact: artifactCount > 0,
        artifact_count: artifactCount,
        data_chunks: dataChunkCount,
      });

      done(true);
    });

    response.data.on('error', (err) => {
      logger.error('[streamAgentNormalized] upstream error', { error: String(err) });
      done(false, err);
    });
  } catch (err) {
    logger.error('[streamAgentNormalized] handler error', { error: String(err?.message || err) });
    done(false, err);
  }
}

module.exports = { streamAgentNormalizedHandler };
