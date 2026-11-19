# Main visual experiment test, based on the OK4 configuration.
# Controls are shown by the stimulus window; the session banner, per-trial
# lines, and the finish line come from the built-in console reporter.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie

include(joinpath(@__DIR__, "_ok_experiment_setup.jl"))

session = create_ok_session(get(ARGS, 1, DEFAULT_PARTICIPANT_ID))
run_experiment!(session)

print_adjustment_summary(session)
visualize_results(session; title = "OK Geometric Experiment Results")

wait_for_enter()
