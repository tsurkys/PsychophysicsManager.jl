# Runs a scenario plan: the sessions it lists, one after another, each replicated
# from a saved session and written to a file of its own. What has been run is
# kept beside the plan, so running the same plan again continues where it
# stopped. The plan format is in the README and in `?load_scenario`.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager

PLAN = get(ARGS, 1, "")
ASK_BETWEEN_RUNS = true   # wait for Enter before each further run; q stops

isempty(PLAN) && error("Name the plan to run: julia examples/run_scenario.jl PLAN.toml")
run_scenario!(resolve_example_path(PLAN); pause_between = ASK_BETWEEN_RUNS)
