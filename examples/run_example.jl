# Headless smoke test: run a complete Constant Stimuli session with the emulator.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using Random

println("Setting up Constant Stimuli experiment...")
Random.seed!(2026)

ex_par = ExperimentParameters(
    "ConstantStimulus",
    :contrast,
    [0.1, 0.2, 0.5, 0.8, 1.0],
    2,
)

stim_par = BaseStimulusParameters(0.0)
method = ConstantStimuli()
# No participant named: the core substitutes DEFAULT_PARTICIPANT_ID ("test_user")
session = SessionContext(ex_par, stim_par, method; tags = ["emulator", "smoke-test"])

# Session banner, per-trial lines, and the finish line (with the checkpoint
# path) come from the built-in console reporter — see the `report` keyword.
run_experiment!(session, EmulatorEngine())

println("\nRaw Data (Valid Trials):")
println("Index | Stimulus Level | Response | Simulated latency (s) | Onset")
println("----------------------------------------------------------------")

for trial in session.history
    if trial.is_valid
        rt = round(trial.timestamp_response - trial.timestamp_onset; digits = 3)
        println(
            lpad(trial.trial_index, 5), " | ",
            lpad(trial.indep_var_vals[1], 14), " | ",
            lpad(trial.response, 8), " | ",
            lpad(rt, 21), " | ", trial.onset_source,
        )
    end
end
println("=========================================")
