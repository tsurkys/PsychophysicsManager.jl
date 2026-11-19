# Prints a readable summary of a saved session (no GUI needed).
# Usage: julia --project=examples examples/inspect_session.jl [SESSION.json]
# Without an argument, the newest .json file in the data directory is used.

include(joinpath(@__DIR__, "_example_setup.jl"))

using Dates
using PsychophysicsManager

filepath = if !isempty(ARGS)
    resolve_example_path(ARGS[1])
else
    newest = newest_session_file()
    if newest === nothing
        println("No saved .json sessions found in: $EXAMPLE_DATA_DIRECTORY")
        exit()
    end
    newest
end

isfile(filepath) || error("Session file not found: $filepath")
session = load_session(filepath)
started = session.start_time === nothing ? "-" : string(unix2datetime(session.start_time))

println("\n=========================================")
println("             SESSION SUMMARY             ")
println("=========================================")

println("\n1. GENERAL:")
println("   ID: ", session.id)
println("   Participant: ", session.participant_id)
println("   State: ", session.state)
println("   Engine: ", session.engine_name)
println("   Program version: ", session.program_version)
println("   Started (UTC): ", started)
println("   Tags: ", isempty(session.tags) ? "-" : join(session.tags, ", "))
println("   Checkpoint: ", session.save_path)

println("\n2. EXPERIMENT PARAMETERS:")
println("   Name: ", session.ex_par.experiment_name)
println("   Variables: ", session.ex_par.indep_var_names)
println("   Ranges: ", session.ex_par.indep_var_ranges)
println("   Repeats: ", session.ex_par.repeats)

println("\n3. STIMULUS PARAMETERS ($(typeof(session.stim_par))):")
for name in fieldnames(typeof(session.stim_par))
    println("   ", name, " = ", getfield(session.stim_par, name))
end

println("\n4. METHOD: ", typeof(session.method_instance))

println("\n5. HISTORY ($(length(session.history)) trials):")
println("   Index | Values | Response | Valid | RT (s) | Onset")
println("   ----------------------------------------------------")
for trial in session.history
    rt = round(trial.timestamp_response - trial.timestamp_onset; digits = 3)
    println(
        "   $(trial.trial_index) | $(trial.indep_var_vals) | " *
        "$(trial.response) | $(trial.is_valid) | $rt | $(trial.onset_source)",
    )
end
println("=========================================")
