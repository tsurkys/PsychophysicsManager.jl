include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie
using REPL.TerminalMenus

selected_file = if !isempty(ARGS)
    path = resolve_example_path(ARGS[1])
    isfile(path) || error("Session file not found: $path")
    path
else
    files = saved_session_files()
    if isempty(files)
        println("No saved .json sessions found in: $EXAMPLE_DATA_DIRECTORY")
        exit()
    end

    labels = basename.(files)
    println("\nSelect a session to inspect:")
    choice = request(RadioMenu(labels; pagesize = 10))
    if choice == -1
        println("Selection cancelled.")
        exit()
    end
    files[choice]
end

println("\nLoading: $selected_file")
session = load_session(selected_file)
print_adjustment_summary(session)
visualize_results(session; title = "Results: $(basename(selected_file))")

wait_for_enter()
