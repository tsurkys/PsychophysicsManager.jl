# Interactive PsychophysicsManager Example
# In this version, YOU provide the responses via the console.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager

# 1. Setup - Constant Stimuli with 3 trials
ex_par = ExperimentParameters(
    "ManualTest",
    :contrast,
    [0.1, 0.5, 1.0],
    1,
)

stim_par = BaseStimulusParameters(500.0)
method = ConstantStimuli()

# 2. Initialize
session = SessionContext(ex_par, stim_par, method)   # default test_user participant

# 3. Use the InteractiveEngine
engine = InteractiveEngine()

# 4. Run the experiment using the clean API
run_experiment!(session, engine)

# 5. Results
println("\n=========================================")
println("          Session Complete               ")
println("=========================================")
for t in session.history
    println("Trial $(t.trial_index): Stim $(t.indep_var_vals[1]) -> Resp $(t.response)")
end
println("Checkpoint: $(session.save_path)")
