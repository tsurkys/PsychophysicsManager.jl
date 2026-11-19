# Interactive Adjustment Method Example (console)
#
# WHAT THIS DEMONSTRATES
#   The method of adjustment: on every trial you tune a COMPARISON duration in
#   fixed steps until it feels equal to the REFERENCE duration announced for
#   that trial, then confirm. What gets recorded is the CONFIRMED value — not
#   your individual keypresses — together with the trial's random starting
#   value (for bias analysis) and the reaction time. A checkpoint JSON is
#   written to the data directory after every trial.
#
# WHAT THE PIECES MEAN
#   - Independent variable `ReferenceDuration_ms`: the condition of the trial
#     (here 500 ms or 1000 ms, each measured twice, in shuffled order).
#   - Dependent variable `duration_ms`: the value YOU adjust, moving through
#     a fixed range (100–1500 ms) in 50 ms steps.
#   - `init_interval`: every trial starts from a random value between 400 and
#     800 ms, so your answers are not anchored by the previous trial.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager

ex_par = ExperimentParameters(
    "AdjustmentConsoleDemo",
    :ReferenceDuration_ms,          # the announced reference of each trial
    [500.0, 1000.0],
    2,                              # 2 conditions × 2 repeats = 4 trials
)

stim_par = BaseStimulusParameters(500.0)   # holds the adjustable duration_ms

method = Adjustment(
    dep_var = :duration_ms,                  # what you adjust...
    dep_range = 100.0:50.0:1500.0,           # ...through this range, 50 ms steps
    init_interval = (400.0, 800.0),          # random starting value per trial
)

session = SessionContext(ex_par, stim_par, method)   # default test_user participant

println("""
YOUR TASK, each trial:
  the STIMULUS line announces ReferenceDuration_ms — imagine a tone of that
  duration; adjust duration_ms with 1 / -1 until it would feel equally long,
  then confirm with 0. The confirmed duration is recorded as the trial result.
""")

run_experiment!(session, InteractiveEngine())

println("\nWhat was recorded (reference → confirmed match, starting point):")
for trial in session.history
    println("  Trial $(trial.trial_index): reference $(trial.indep_var_vals[1]) ms",
            " → confirmed $(trial.response) ms",
            " (started at $(trial.start_value) ms,",
            " RT $(round(trial.timestamp_response - trial.timestamp_onset; digits=1)) s)")
end
println("\nThe same history was checkpointed to: $(session.save_path)")
println("Inspect it later with: julia examples/inspect_session.jl")
