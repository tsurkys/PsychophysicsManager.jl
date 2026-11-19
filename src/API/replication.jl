# Replicating a saved session: turning a session file back into a runnable
# session, and the console workflow that picks one. Separated from the session
# control commands next door — these functions load files, activate backends and
# talk to the operator's terminal, none of which a state command may do.

using REPL.TerminalMenus: RadioMenu, request

"""
    create_replicated_session(filepath::String,
                              new_participant_id::String=DEFAULT_PARTICIPANT_ID)

Loads a saved experiment configuration, activates its built-in rendering backend when
needed, and returns a new `READY` session with fresh method state. It does not run the
session. This is useful for operator interfaces that should let an operator inspect and
start a replication separately. A file holding a saved [`AnalysisSet`](@ref) is
replicated from its last session.
"""
function create_replicated_session(filepath::String,
                                   new_participant_id::String=DEFAULT_PARTICIPANT_ID)
    source_session = _load_replicable_session(filepath)
    return create_replicated_session(source_session, new_participant_id)
end

"""
    create_replicated_session(source_session::SessionContext,
                              new_participant_id::String=DEFAULT_PARTICIPANT_ID)

Creates a `READY` replication of an already loaded session. Experiment and stimulus
parameters are copied so runtime changes in the new session cannot mutate the saved
template held by the caller.
"""
function create_replicated_session(source_session::SessionContext,
                                   new_participant_id::String=DEFAULT_PARTICIPANT_ID)
    new_session = SessionContext(
        new_participant_id,
        deepcopy(source_session.ex_par),
        deepcopy(source_session.stim_par),
        fresh_instance(source_session.method_instance),
    )
    new_session.engine_name = source_session.engine_name
    new_session.tags = copy(source_session.tags)
    # Part of the experiment's design, like the method configuration: a
    # replication measures the same kind of data as its template, asks the same
    # question in the same words, trains or measures as its template did, and is
    # reported in the same units
    new_session.fit_gamma = source_session.fit_gamma
    new_session.task = source_session.task
    new_session.feedback = source_session.feedback
    new_session.timeout_s = source_session.timeout_s
    new_session.messages = source_session.messages
    new_session.unit_conversions = copy(source_session.unit_conversions)
    # The seed is pointedly not copied: a replication repeats the design, and a
    # replication that also repeated the trial order would confound the two
    return new_session
end

"""
    create_replicated_session(set::AnalysisSet,
                              new_participant_id::String=DEFAULT_PARTICIPANT_ID)

A `READY` replication of the set's last session: a new experiment set up from a
combined dataset starts from the design of the session added to it last.
"""
create_replicated_session(set::AnalysisSet,
                          new_participant_id::String=DEFAULT_PARTICIPANT_ID) =
    create_replicated_session(design_session(set), new_participant_id)

# The session a file describes, as a template: a combined dataset's last session. Its
# engine's backend is not loaded here, so a window can read a template without
# stopping to load a graphics or audio package.
function read_replicable_session(filepath::String)
    document = read_json_document(filepath)
    source_session = is_analysis_set_document(document) ?
                     design_session(analysis_set_from_document(document, filepath)) :
                     dict_to_session(document)
    source_session.engine_name == "UnknownEngine" && error(
        "The source session does not identify a restorable stimulus engine.",
    )
    return source_session
end

function _load_replicable_session(filepath::String)
    source_session = read_replicable_session(filepath)
    activate_engine_backend!(source_session.engine_name)
    return source_session
end

# Restores the engine the session names, runs the session on it and closes it. The
# run is entered through `invokelatest`: a backend loaded by the caller a moment before
# (`activate_engine_backend!`) defines its engine in a newer world than the caller's,
# and code already running would not see it.
run_restored!(session::SessionContext; on_trial_end = nothing, report::Symbol = :trials,
              accept_changed_stimulus::Bool = false) =
    Base.invokelatest(_run_restored!, session, on_trial_end, report, accept_changed_stimulus)

function _run_restored!(session::SessionContext, on_trial_end, report::Symbol,
                        accept_changed_stimulus::Bool)
    engine = restore_engine(session, load_display_config())
    try
        run_experiment!(session, engine; on_trial_end, report, accept_changed_stimulus)
    finally
        close_engine!(engine)
    end
    return session
end

"""
    replicate_experiment(filepath::String,
                         new_participant_id::String=DEFAULT_PARTICIPANT_ID;
                         on_trial_end=nothing, report=:trials)

Loads an experiment configuration from a saved JSON file, creates a new session with
the same parameters and fresh method state, restores the required rendering engine, and
runs the experiment.
"""
function replicate_experiment(filepath::String, new_participant_id::String=DEFAULT_PARTICIPANT_ID;
                              on_trial_end=nothing, report::Symbol=:trials)
    source_session = _load_replicable_session(filepath)
    return replicate_experiment(source_session, new_participant_id;
                                on_trial_end=on_trial_end, report=report)
end

function replicate_experiment(source_session::SessionContext,
                              new_participant_id::String=DEFAULT_PARTICIPANT_ID;
                              on_trial_end=nothing, report::Symbol=:trials)
    new_session = create_replicated_session(source_session, new_participant_id)
    return run_restored!(new_session; on_trial_end, report)
end

function _choose_session_file(data_directory::String=resolve_data_dir())
    isdir(data_directory) || error("Session data directory does not exist: $data_directory")
    candidates = sort(filter(path -> endswith(lowercase(path), ".json"), readdir(data_directory; join=true)))
    isempty(candidates) && error("No .json session files were found in: $data_directory")

    selected = request(RadioMenu(basename.(candidates); pagesize=min(length(candidates), 12)))
    selected == -1 && error("Session selection cancelled.")
    return candidates[selected]
end

"""
    run_session_from_file(filepath::String="";
                          participant_id::String=DEFAULT_PARTICIPANT_ID)

Runs a fresh replication of a saved JSON session. When `filepath` is empty, a terminal
menu lists JSON files in the configured `data/` directory. Optional built-in graphics
and audio backends are activated automatically from the saved session's `engine_name`.
"""
function run_session_from_file(filepath::String="";
                               participant_id::String=DEFAULT_PARTICIPANT_ID)
    source_path = isempty(filepath) ? _choose_session_file() : abspath(filepath)
    source_session = _load_replicable_session(source_path)
    # The experiment, the participant and the progress are announced by the
    # console reporter once the loop starts; which file is being
    # replicated, and on which engine, is known only here.
    println("Replicating $source_path on $(source_session.engine_name).")
    return replicate_experiment(source_session, participant_id)
end
