"""
Canvas Orchestrator Agent Engine Entry Point.

4-Lane Architecture (Single Shell Agent):
- Fast Lane: Regex patterns → direct skill execution (no LLM, <500ms)
- Slow Lane: ShellAgent (gemini-2.5-flash) for conversational reasoning
- Functional Lane: gemini-2.5-flash for JSON-only Smart Button logic
- Worker Lane: Background scripts (triggered by PubSub, not routed here)

Pipeline Events:
This module emits _pipeline events at each stage of the reasoning chain:
- router: Lane routing decision (FAST/SLOW/FUNCTIONAL)
- planner: Tool plan generation (intent, data_needed, rationale, tools)
- thinking: Gemini extended thinking (if enabled)
- critic: Response validation result
These events flow through Firebase to iOS for logging/display.
"""

import datetime
import json
import logging
import os
import time
from typing import Any, Dict, Generator, List, Optional
from collections.abc import Mapping, Sequence

import google.auth
import vertexai
from google.cloud import logging as google_cloud_logging
from vertexai import agent_engines
from vertexai.preview.reasoning_engines import AdkApp

# Import the unified Shell Agent
from app.shell import create_shell_agent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Validate GOOGLE_APPLICATION_CREDENTIALS if set — fail loud, not silent.
# On Vertex AI runtime this env var is absent (ADC is used), so only check
# when present (i.e. local dev / deploy commands).
gac = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
if gac and not os.path.exists(gac):
    logger.warning(
        "GOOGLE_APPLICATION_CREDENTIALS points to missing file: %s  "
        "Unsetting to fall back to ADC. If deploy fails with PermissionDenied, "
        "set it to the GCP SA key: ~/.config/povver/myon-53d85-80792c186dcb.json",
        gac,
    )
    os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)


class AgentEngineApp(AdkApp):
    """
    AdkApp with 4-Lane pipeline for optimal latency.
    
    The stream_query method routes requests through:
    1. Context Setup - Establishes security boundary
    2. Router - Determines lane (Fast/Slow/Functional)
    3. Fast Lane - Direct skill execution (<500ms)
    4. Functional Lane - Flash-based JSON logic
    5. Slow Lane - LLM with optional Plan + Critic
    """
    
    def set_up(self) -> None:
        super().set_up()
        logging_client = google_cloud_logging.Client()
        try:
            logging_client.setup_logging()
        except Exception:
            pass
        self.logger = logging_client.logger(__name__)
        try:
            import google.adk as _adk
            import google.genai as _genai
            logger.info(
                f"Runtime versions: google-adk={getattr(_adk, '__version__', 'unknown')}, google-genai={getattr(_genai, '__version__', 'unknown')}"
            )
        except Exception:
            logger.info("Runtime versions: not available")
        
        logger.info("Canvas Orchestrator initialized (Shell Agent, 4-Lane Pipeline)")

    def stream_query(
        self,
        *,
        user_id: str,
        session_id: str,
        message: str,
        **kwargs,
    ) -> Generator[dict, None, None]:
        """
        Full 4-Lane Pipeline: Router → Fast/Functional/Slow → Critic
        """
        start_time = time.time()

        from app.shell.context import SessionContext, set_current_context
        from app.shell.router import route_request, execute_fast_lane, Lane
        from app.shell.planner import generate_plan, should_generate_plan

        routing = None
        plan = None
        ctx = None

        # === SECURITY BOUNDARY: Context from authenticated request ===
        # user_id is derived from the authenticated Vertex AI request, NOT from LLM output.
        # All downstream tool calls retrieve user_id via get_current_context() (contextvars).
        # ContextVar is required because Vertex AI Agent Engine runs concurrent requests
        # in the same process — module-level globals would leak user data across requests.
        try:
            ctx = SessionContext.from_message(message)
            set_current_context(ctx, message)
            logger.debug("Context set: user=%s conv=%s", ctx.user_id, ctx.conversation_id)
        except Exception as e:
            logger.error("Failed to set context: %s", e)
        
        # === 2. ROUTING ===
        try:
            routing = route_request(message)
        except Exception as e:
            logger.error("Router error: %s", e)
            routing = None
        
        # === EMIT: Router decision ===
        if routing:
            yield self._create_pipeline_event("router", {
                "lane": routing.lane.value if hasattr(routing.lane, "value") else str(routing.lane),
                "intent": routing.intent,
                "signals": routing.signals,
            })
        
        # === 3. FAST LANE: Direct skill execution ===
        if routing and routing.lane == Lane.FAST:
            logger.info("FAST LANE: %s → %s", message[:30], routing.intent)

            try:
                result = execute_fast_lane(routing, message, ctx)
                yield self._format_fast_lane_response(result, routing.intent)
                self._log_request_completed(start_time, routing, ctx)
                return
            except Exception as e:
                logger.error("Fast lane error: %s - falling back to Slow", e)
        
        # === 4. FUNCTIONAL LANE: Flash-based JSON logic ===
        if routing and routing.lane == Lane.FUNCTIONAL:
            logger.info("FUNCTIONAL LANE: intent=%s", routing.intent)
            
            try:
                import asyncio
                from app.shell.functional_handler import execute_functional_lane
                
                # Parse JSON payload
                if isinstance(message, str) and message.strip().startswith('{'):
                    try:
                        payload = json.loads(message)
                    except json.JSONDecodeError:
                        payload = {"message": message}
                elif isinstance(message, dict):
                    payload = message
                else:
                    payload = {"message": message}
                
                # Execute async handler
                try:
                    loop = asyncio.get_running_loop()
                    import nest_asyncio
                    nest_asyncio.apply()
                    result = loop.run_until_complete(
                        execute_functional_lane(routing, payload, ctx)
                    )
                except RuntimeError:
                    result = asyncio.run(
                        execute_functional_lane(routing, payload, ctx)
                    )
                
                yield self._format_functional_lane_response(result, routing.intent)
                self._log_request_completed(start_time, routing, ctx)
                return
            except Exception as e:
                logger.error("Functional lane error: %s - falling back to Slow", e)
        
        # === WORKOUT BRIEF: Front-load active workout state for LLM context ===
        # Fetches workout state once per request (not per LLM turn) and prepends it
        # to the message. This gives the LLM exercise names, set IDs, and progress
        # without requiring a tool call. Skipped for Fast Lane (no LLM needed).
        # Called by: WorkoutCoachViewModel.swift → streamAgentNormalized → here
        augmented_message = message
        if ctx.workout_mode and ctx.active_workout_id:
            if not (routing and routing.lane == Lane.FAST):
                try:
                    from app.skills.workout_skills import get_workout_state_formatted
                    workout_brief = get_workout_state_formatted(
                        ctx.user_id, ctx.active_workout_id
                    )
                    if workout_brief:
                        augmented_message = f"{workout_brief}\n\n{augmented_message}"
                        logger.info("WORKOUT BRIEF: injected %d chars", len(workout_brief))
                except Exception as e:
                    logger.warning("Workout brief error: %s", e)

        # === 5. TOOL PLANNER: Generate plan for Slow Lane ===
        if routing and should_generate_plan(routing):
            try:
                plan = generate_plan(routing, message)
                logger.info("PLANNER: Generated plan for %s", routing.intent)

                # === EMIT: Planner output ===
                if plan and not plan.skip_planning:
                    yield self._create_pipeline_event("planner", {
                        "intent": plan.intent,
                        "data_needed": plan.data_needed,
                        "rationale": plan.rationale,
                        "suggested_tools": plan.suggested_tools,
                    })
            except Exception as e:
                logger.warning("Planner error: %s", e)

        # === 6. SLOW LANE: LLM execution ===
        logger.info("SLOW LANE: %s (intent=%s)", message[:50], routing.intent if routing else "unknown")

        # Inject planning context if available (appends to end, after workout brief)
        if plan and not plan.skip_planning:
            plan_prompt = plan.to_system_prompt()
            augmented_message = f"{augmented_message}\n\n{plan_prompt}"
            logger.info("PLANNER: Injected plan for %s", plan.intent)
        
        # Collect response for critic pass
        collected_text = []

        # Reset per-request usage accumulator (populated by after_model_callback)
        from app.shell.agent import _usage_accumulator
        _usage_accumulator.set(None)

        for chunk in super().stream_query(
            user_id=user_id,
            session_id=session_id,
            message=augmented_message,
            **kwargs,
        ):
            # Collect text for critic
            try:
                candidates = chunk.get("candidates", [])
                if candidates:
                    parts = candidates[0].get("content", {}).get("parts", [])
                    for part in parts:
                        if "text" in part:
                            collected_text.append(part["text"])
            except Exception:
                pass

            yield chunk

        # === USAGE TRACKING: Read from after_model_callback ContextVar ===
        # ADK Events don't carry usage_metadata, so chunk-based accumulation
        # never works.  The after_model_callback on ShellAgent captures token
        # counts directly from LlmResponse and stores them in _usage_accumulator.
        usage_data = _usage_accumulator.get()
        if usage_data and usage_data.get("total_tokens"):
            try:
                from shared.usage_tracker import track_usage
                track_usage(
                    user_id=ctx.user_id if ctx else None,
                    category="user_initiated",
                    system="canvas_orchestrator",
                    feature="shell_agent",
                    model=os.getenv("CANVAS_SHELL_MODEL", "gemini-2.5-flash"),
                    **usage_data,
                )
            except Exception as e:
                logger.debug("Usage tracking error (non-fatal): %s", e)

        # === 7. CRITIC PASS: Validate response ===
        if routing and collected_text:
            try:
                from app.shell.critic import run_critic, should_run_critic
                
                full_response = "".join(collected_text)
                
                if should_run_critic(routing.intent, len(full_response)):
                    critic_result = run_critic(
                        response=full_response,
                        response_type="coaching" if "ANALYZE" in (routing.intent or "") else "general",
                    )
                    
                    # === EMIT: Critic result ===
                    yield self._create_pipeline_event("critic", {
                        "passed": not critic_result.has_errors,
                        "findings": [f.message for f in critic_result.findings] if critic_result.findings else [],
                        "errors": critic_result.error_messages if critic_result.has_errors else [],
                    })
                    
                    if critic_result.has_errors:
                        logger.warning("CRITIC: Response failed safety check: %s", 
                                      critic_result.error_messages)
                    elif critic_result.findings:
                        logger.info("CRITIC: %d warnings (passed)", len(critic_result.findings))

            except Exception as e:
                logger.debug("Critic error: %s", e)

        self._log_request_completed(start_time, routing, ctx)

    def _log_request_completed(self, start_time, routing, ctx):
        """Emit structured completion log for all lanes."""
        try:
            lane = "unknown"
            if routing and hasattr(routing.lane, "value"):
                lane = routing.lane.value
            elif routing:
                lane = str(routing.lane)
            logger.info(json.dumps({
                "event": "agent_request_completed",
                "lane": lane,
                "intent": routing.intent if routing else None,
                "workout_mode": ctx.workout_mode if ctx else False,
                "latency_ms": int((time.time() - start_time) * 1000),
                "user_id": ctx.user_id if ctx else None,
            }))
        except Exception:
            pass

    def _format_fast_lane_response(self, result: dict, intent: str) -> dict:
        """Format fast lane result as ADK-compatible streaming response."""
        skill_result = result.get("result", {})
        
        if isinstance(skill_result, dict):
            text = skill_result.get("message", "Done.")
        else:
            text = str(skill_result)
        
        return {
            "candidates": [{
                "content": {
                    "parts": [{"text": text}],
                    "role": "model"
                },
                "finish_reason": "STOP",
            }],
            "usage_metadata": {
                "prompt_token_count": 0,
                "candidates_token_count": len(text.split()),
                "total_token_count": len(text.split()),
            },
            "model_version": "fast-lane-bypass",
            "_metadata": {
                "fast_lane": True,
                "intent": intent,
                "latency_class": "fast",
            }
        }
    
    def _format_functional_lane_response(self, result: dict, intent: str) -> dict:
        """Format functional lane result as ADK-compatible response."""
        func_result = result.get("result", {})
        
        # NULL action = silent observer
        if func_result.get("action") == "NULL":
            return {
                "candidates": [{
                    "content": {
                        "parts": [{"text": ""}],
                        "role": "model"
                    },
                    "finish_reason": "STOP",
                }],
                "usage_metadata": {
                    "prompt_token_count": 0,
                    "candidates_token_count": 0,
                    "total_token_count": 0,
                },
                "model_version": "functional-lane-flash",
                "_metadata": {
                    "functional_lane": True,
                    "intent": intent,
                    "action": "NULL",
                    "latency_class": "functional",
                }
            }
        
        json_text = json.dumps(func_result, indent=2)
        
        return {
            "candidates": [{
                "content": {
                    "parts": [{"text": json_text}],
                    "role": "model"
                },
                "finish_reason": "STOP",
            }],
            "usage_metadata": {
                "prompt_token_count": 0,
                "candidates_token_count": len(json_text.split()),
                "total_token_count": len(json_text.split()),
            },
            "model_version": "functional-lane-flash",
            "_metadata": {
                "functional_lane": True,
                "intent": intent,
                "action": func_result.get("action", "UNKNOWN"),
                "latency_class": "functional",
            }
        }
    
    def _create_pipeline_event(self, step: str, data: dict) -> dict:
        """
        Create a pipeline event for CoT visibility.
        
        Pipeline events are special events that expose the agent's reasoning chain:
        - router: Lane routing decision
        - planner: Tool plan generation
        - thinking: LLM internal reasoning (if Gemini thinking enabled)
        - critic: Response validation result
        
        These events are passed through Firebase to iOS for logging/display.
        """
        return {
            "_pipeline": {
                "type": step,
                "timestamp": time.time(),
                **data,
            }
        }

    def register_operations(self) -> Mapping[str, Sequence]:
        operations = super().register_operations()
        return operations


def _read_requirements(path: str) -> list[str]:
    with open(path) as f:
        return [ln.strip() for ln in f.read().splitlines() if ln.strip() and not ln.strip().startswith("#")]


# Create the root agent using Shell Agent
root_agent = create_shell_agent()


def deploy_canvas_orchestrator(
    project: str,
    location: str,
    agent_name: Optional[str] = "canvas-orchestrator",
    requirements_file: str = "agent_engine_requirements.txt",
    extra_packages: Optional[List[str]] = None,
    env_vars: Optional[Dict[str, str]] = None,
) -> agent_engines.AgentEngine:
    if extra_packages is None:
        extra_packages = ["./app", "../shared"]
    if env_vars is None:
        env_vars = {}
    staging_bucket_uri = f"gs://{project}-agent-engine"
    try:
        from google.cloud import storage
        client = storage.Client(project=project)
        name = staging_bucket_uri.replace("gs://", "")
        bucket = client.bucket(name)
        if not bucket.exists():
            client.create_bucket(bucket, location=location)
    except Exception:
        pass

    vertexai.init(project=project, location=location, staging_bucket=staging_bucket_uri)

    requirements = _read_requirements(requirements_file)

    agent_engine = AgentEngineApp(agent=root_agent)

    env_vars = dict(env_vars or {})
    env_vars = {k: v for k, v in env_vars.items() if str(v).strip() != ""}
    env_vars.setdefault("NUM_WORKERS", "1")
    env_vars.setdefault("MYON_FUNCTIONS_BASE_URL", "https://us-central1-myon-53d85.cloudfunctions.net")
    if "FIREBASE_API_KEY" not in env_vars and not os.getenv("FIREBASE_API_KEY"):
        raise RuntimeError("FIREBASE_API_KEY env var is required for deployment")
    env_vars.setdefault("FIREBASE_API_KEY", os.getenv("FIREBASE_API_KEY", ""))

    existing = list(agent_engines.list(filter=f"display_name={agent_name}"))
    if existing:
        try:
            existing_id = existing[0].resource_name.split("/")[-1]
            env_vars.setdefault("ADK_APP_NAME", existing_id)
            logging.info(f"Setting ADK_APP_NAME to existing engine id {existing_id}")
        except Exception:
            pass

    cfg: dict[str, Any] = {
        "agent_engine": agent_engine,
        "display_name": agent_name,
        "description": "Canvas Orchestrator (Shell Agent, 4-Lane Pipeline)",
        "extra_packages": extra_packages,
        "env_vars": env_vars,
        "requirements": requirements,
    }
    logging.info(f"Canvas Orchestrator config: {cfg}")

    if existing:
        logging.info(f"Updating existing Canvas Orchestrator: {agent_name}")
        remote = existing[0].update(**cfg)
    else:
        logging.info(f"Creating Canvas Orchestrator: {agent_name}")
        remote = agent_engines.create(**cfg)

    logging.info(f"Deployed agent with resource name: {remote.resource_name}")

    with open("deployment_metadata.json", "w") as f:
        json.dump({"remote_agent_engine_id": remote.resource_name, "deployment_timestamp": datetime.datetime.now().isoformat()}, f, indent=2)
    return remote


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Deploy Canvas Orchestrator Agent")
    parser.add_argument("--project", default=None)
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--agent-name", default="canvas-orchestrator")
    parser.add_argument("--requirements-file", default="agent_engine_requirements.txt")
    parser.add_argument("--extra-packages", nargs="+", default=["./app"])
    parser.add_argument("--set-env-vars")
    args = parser.parse_args()

    env_vars = {}
    if args.set_env_vars:
        for pair in args.set_env_vars.split(","):
            if not pair:
                continue
            k, v = pair.split("=", 1)
            env_vars[k] = v

    if not args.project:
        _, args.project = google.auth.default()

    deploy_canvas_orchestrator(
        project=args.project,
        location=args.location,
        agent_name=args.agent_name,
        requirements_file=args.requirements_file,
        extra_packages=args.extra_packages,
        env_vars=env_vars,
    )
