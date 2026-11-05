
import argparse
import os
from dotenv import load_dotenv

load_dotenv()

from agent import budget
from agent.budget import BudgetTracker
from agent.claude_client import MODEL
from datetime import datetime

from agent.tools import (
    get_state,
    get_image,
    execute_action,
    validate_action,
    get_depth,
    start_run,
    end_run,
    reset_scene,
)
from agent.logger import RunLogger
from agent.path_overlay import add_path_guide
from agent.commands import is_free_throw


MAX_STEPS = 60


def dummy_decision(step):
    actions = [
        ("turn", {"degrees": 30}),
        ("move", {"distance": 1.0}),
        ("turn", {"degrees": -30}),
        ("move", {"distance": 0.5}),
        ("pickup", {}),
        ("turn", {"degrees": 180}),
        ("move", {"distance": 1.0}),
        ("drop", {})
    ]

    if step >= len(actions):
        return None

    return {
        "name": actions[step][0],
        "arguments": actions[step][1]
    }


def run_agent(command, mode, reset=False, final=False):
    run_id = datetime.now().strftime(
        "%Y%m%d_%H%M%S"
    )

    logger = RunLogger(run_id)
    budget = BudgetTracker()
    run_cost = 0.0
    collision_count = 0

    print("\nROBOT AGENT STARTED")
    print("Mode:", mode)
    print("Command:", command)
    print("Run ID:", run_id)
    free_throw = is_free_throw(command)
    if free_throw:
        print("Task: free throw (passes when the throw succeeds, wherever it lands)")

    if mode == "claude":
        # $40 team budget: practice runs stop at $30 so money is left for the judged runs.
        # Judged runs (--final) always go ahead and are recorded separately.
        model_type = "haiku" if "haiku" in MODEL.lower() else "sonnet"
        if not budget.can_start_run(model_type, development=not final):
            budget.show_summary()
            print("Run NOT started: practice budget used up. Use --final for judged runs.")
            return

    if reset:
        reset_scene()
        print("Scene reset to start positions")

    start_run(command, run_id)
    outcome = "fail_not_reached"

    claude = None
    try:
        if mode == "claude":
            if not os.getenv("ANTHROPIC_API_KEY"):
                raise RuntimeError(
                    "ANTHROPIC_API_KEY is not set. "
                    "Use --mode dummy for testing."
                )
            from agent.claude_client import ClaudeRobotClient
            claude = ClaudeRobotClient()
        elif mode == "mock":
            from agent.mock_claude import MockClaudeClient
            claude = MockClaudeClient()
        elif mode == "openrouter":
            # Any OpenRouter model with image + tool support; development only, not judged runs.
            from agent.openrouter_client import OpenRouterRobotClient, MODEL as OR_MODEL
            claude = OpenRouterRobotClient()
            print("OpenRouter model:", OR_MODEL)
        elif mode == "vision":
            # No-API stand-in that reads the camera pixels; for testing only, not judged runs.
            from agent.vision_brain import VisionBrain
            claude = VisionBrain()

        # Brief: one /look after each /move or /turn, and never two images in a row
        # without a move or turn in between. After pickup/drop/throw (or a rejected
        # action) the model gets no new image, only the tool result.
        need_look = True
        image = depth = None
        for step in range(MAX_STEPS):
            new_image = need_look
            if need_look:
                image = get_image()
                depth = get_depth()
                if mode in ("claude", "openrouter"):
                    # Show the model how wide the robot's path is (camera geometry only, no object data).
                    image = add_path_guide(image)

            if mode == "dummy":
                decision = dummy_decision(step)
                if decision is None:
                    break
            elif mode in ("claude", "openrouter"):
                decision = claude.decide(command, image if new_image else None, depth)
            else:
                # The pixel-based stand-ins are not Claude; they can reuse the last frame.
                decision = claude.decide(command, image, depth)
            if mode == "claude":
                model_type = "haiku" if "haiku" in MODEL.lower() else "sonnet"
                step_cost = budget.estimate_cost(
                    model_type,
                    decision["input_tokens"],
                    decision["output_tokens"],
                )
                run_cost += step_cost
                print(f"Estimated API cost: ${step_cost:.6f}")

            action = decision["name"]
            arguments = decision["arguments"]
            print(f"\nSTEP {step + 1}")
            print("Action:", action)
            print("Arguments:", arguments)

            if action == "give_up":
                if mode in ("mock", "claude", "vision", "openrouter"):
                    claude.record_result({
                        "gave_up": True,
                        "reason": arguments.get("reason", ""),
                    })
                print("Agent gave up:", arguments.get("reason"))
                break

            engine_args = {}
            if action == "turn":
                engine_args["degrees"] = arguments["degrees"]
            elif action in ("move", "throw"):
                engine_args["distance"] = arguments["distance"]
            elif action not in ("pickup", "drop"):
                raise ValueError(f"Unknown action: {action}")

            try:
                validate_action(action, engine_args)
                result = execute_action(action, engine_args)
            except (ValueError, KeyError) as error:
                result = {
                    "success": False,
                    "error": str(error),
                    "action_rejected": True,
                }
                print("Action rejected:", error)

            # Only a move or turn that actually ran changes the view.
            need_look = action in ("move", "turn") and not result.get("action_rejected")

            if result.get("collided") is True:
                collision_count += 1
                print(f"Collision detected! Total: {collision_count}")
            elif action == "move" and result.get("collided") is False:
                collision_count = 0

            if collision_count >= 3:
                print("WARNING: Three consecutive collisions. Robot may be stuck.")

            if mode in ("mock", "claude", "vision", "openrouter"):
                claude.record_result(result)

            logger.save_step(
                step=step + 1,
                image_bytes=image,
                tool=action,
                args=engine_args,
                result=result,
                observation=arguments.get("observation", "Camera not analysed"),
                reasoning=arguments.get("reasoning", "Predefined action for testing"),
            )
            print("Result:", result)
            print("Logged successfully")

            if result.get("state") == "Done":
                outcome = "fail_collision" if result.get("collided") else "fail_not_reached"
                print("Engine ended the run.")
                break

            if free_throw and action == "throw" and result.get("success"):
                print("\nThrow done!")
                outcome = "pass"
                break

            if action in ("drop", "throw") and result.get("success") and result.get("in_zone"):
                print("\nDelivery confirmed!")
                outcome = "pass"
                break
            # (no pause between steps: the engine replies only after the motion ends)

        if mode == "claude":
            budget.record_run(run_id, run_cost, development=not final)
            budget.show_summary()
        print("\nRUN COMPLETED")
        print("Logs saved in:", logger.run_folder)
    finally:
        end_run(outcome)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "command",
        nargs="?",
        default="Bring the red cube"
    )

    parser.add_argument(
        "--mode",
        choices=["dummy", "mock", "claude", "vision", "openrouter"],
        default="dummy"
    )

    parser.add_argument(
        "--final",
        action="store_true",
        help="judged run: always allowed by the budget guard, not counted as practice",
    )

    parser.add_argument(
        "--reset",
        action="store_true",
        help="put the robot and objects back at their start positions first",
    )

    args = parser.parse_args()

    run_agent(args.command, args.mode, reset=args.reset, final=args.final)


if __name__ == "__main__":
    main()
