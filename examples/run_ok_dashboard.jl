# Dashboard integration test using the main Diana/OK4 visual stimulus.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie                          # the stimulus window
using CImGui, ImPlot, GLFW, ModernGL   # the operator dashboard

include(joinpath(@__DIR__, "_ok_experiment_setup.jl"))

participant_id = get(ARGS, 1, DEFAULT_PARTICIPANT_ID)
session = create_ok_session(participant_id; extra_tags = ["dashboard-test"])

display_config = load_display_config()
display_config.title = "OK Dashboard Stimulus"
engine = initialize_engine(default_engine_type(session.stim_par), session.stim_par,
                           display_config)

dashboard = open_operator_dashboard(session)
println("\n── OK operator dashboard test ──")
println("1. Click Start Session in the dashboard window.")
println("2. Focus the stimulus window for participant responses.")
println("3. Use the dashboard to pause, resume, or undo.")

# Waits for Start in the dashboard, then runs the trial loop here (Ctrl+C pauses it)
run_when_started!(session, engine, dashboard)

if session.state == READY
    println("Dashboard closed before the session was started.")
    exit()
end

print_adjustment_summary(session)
wait_for_enter()

visualize_results(session; title = "OK Dashboard Experiment Results")
wait_for_enter()
