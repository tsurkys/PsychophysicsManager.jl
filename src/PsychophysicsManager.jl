module PsychophysicsManager

const PEM = PsychophysicsManager
export PEM

# Core is headless by design: no graphics or audio dependencies here.
# Visual/audio engines, the dashboard, and plotting live in package
# extensions (ext/) activated by loading the corresponding backend:
#   using GLMakie                     -> visual engine, dashboard, plots
#   using CairoMakie                  -> plots (headless rendering)
#   using PortAudio, SampledSignals   -> audio engine
using UUIDs
using Dates
using Random
using Statistics
using JSON3

# Root abstract types and type registries (must come first)
include("Core/abstractions.jl")
include("Core/registry.jl")
include("Core/stimulus_parameters.jl")

# Include core components
include("Core/task.jl")
include("Core/messages.jl")
include("Core/units.jl")
include("Core/session.jl")
include("Core/extension_stubs.jl")

# Include method interfaces and specific methods
include("Analytics/psychometric_functions.jl")
include("Methods/interface.jl")
include("Methods/constant_stimuli.jl")
include("Methods/adjustment.jl")
include("Methods/staircase.jl")
include("Methods/psi.jl")
include("Methods/interleaved.jl")

# Presentation: how a stimulus reaches the participant and how the response
# comes back (engine contract, response sources, headless built-in engines)
include("Presentation/config.jl")
include("Presentation/engine.jl")
include("Presentation/identity.jl")
include("Presentation/response.jl")
include("Presentation/binding.jl")
include("Presentation/emulator.jl")
include("Presentation/interactive.jl")
include("Presentation/remote.jl")

# Stimuli: what is presented — parameters and pure generation, no devices
include("Stimuli/scoring.jl")
include("Stimuli/marker_layout.jl")
include("Stimuli/render.jl")
include("Stimuli/gabor.jl")
include("Stimuli/audio.jl")

# Programmatic participants: a render-only engine that hands over its pixel
# buffer, and the model-observer contract that answers from it. Both dispatch on
# concrete stimulus descriptions, so they come after Stimuli/.
include("Presentation/offscreen.jl")
include("Observers/interface.jl")
include("Observers/simulated.jl")
include("Observers/source.jl")
include("Observers/factory.jl")
include("Observers/run.jl")

# Include IO and API. A combined dataset is stored the way its sessions are and is
# read by the export and every analysis, so it comes between storage and those.
include("IO/settings.jl")
include("IO/storage.jl")
include("Analytics/analysis_set.jl")
include("IO/export.jl")
include("API/commands.jl")
include("API/replication.jl")
include("API/parameters.jl")
include("API/scenario.jl")
include("API/participants.jl")
include("API/library.jl")
include("API/reporting.jl")

# Operator-UI layer: the text and the control logic of the dashboard, kept
# headless so a front end only renders them (the GLMakie widgets live in ext/)
include("UI/locale.jl")
include("UI/labels.jl")
include("UI/controller.jl")
include("UI/combining.jl")

# Include Analytics (aggregation and fitting; plotting is in extensions)
include("Analytics/processing.jl")
include("Analytics/fitting.jl")
include("Analytics/adaptive.jl")

# What the dashboard's live plot draws: it is built on the aggregation above
include("UI/live_plot.jl")
include("UI/setup_view.jl")
include("UI/browse.jl")
include("UI/data_view.jl")
include("UI/settings_view.jl")
include("UI/control_channel.jl")
include("UI/window_icon.jl")

# Include the main execution loop
include("Core/loop.jl")

# Session construction and lifecycle
export SessionContext, SessionMessages, ParticipantMessage, ExperimentParameters, Trial, BaseStimulusParameters, AbstractStimulusParameters
export SessionComment
export DEFAULT_PARTICIPANT_ID
export SessionState, READY, RUNNING, PAUSED, ABORTED, FINISHED

# What the observer is asked, and what an answer means
export ObserverTask, length_comparison_task, response_code

# Psychophysical methods
export AbstractPsychoMethod, ConstantStimuli, Adjustment, Staircase, Psi
export Interleaved, TRACK_VARIABLE
export method_threshold

# Stimulus descriptions (what is presented) and the correct answer they define
export correct_answer, physical_equality, trial_variables, validate_stimulus,
       task_scoring
export MarkerLayout, calculate_marker_layout, render_stimulus!, draw_marker!
export Gabor
export TemporalOppelKundt, temporal_oppel_kundt_onsets
export generate_temporal_oppel_kundt_waveform
export WorkerStimulus, parameter_names, parameter_value, set_parameter!, numeric_parameters,
       required_variables

# Presentation: engines, their contract, and variable binding (how it reaches
# the participant). Concrete backend engines live in the extensions.
export AbstractStimulusEngine, EmulatorEngine, InteractiveEngine, OffscreenVisualEngine
export RemoteEngine, declared_stimuli, worker_stimulus
export DisplayConfig, initialize_engine, close_engine!, restore_engine, default_engine_type
export present_stimulus, PresentationResult, last_frame, display_info, canvas_size
export present_feedback, present_message, set_response_timeout!, can_abandon_presentation, abandon_presentation!
export set_min_response_time!
export declared_parameters
export preview_stimulus
export engine_version, stimulus_identity, StimulusChangedError, UNKNOWN_STIMULUS_VERSION
export verify_engine, EngineReport
export apply_variables!, set_converted!

# Response sources (how the response comes back)
export AbstractResponseSource, ConsoleResponseSource, ScriptedResponseSource
export TrialContext
export request_response, set_response_source!, swap_response_source!,
       with_response_source, discard_pending_responses!, reads_messages

# Model observers (programmatic participants: simulated, or an external model)
export AbstractObserverBackend, ObserverQuestion, ObserverAnswer,
       ObserverRecord, ModelObserverSource, SimulatedObserver
export query_observer, segment_lengths,
       invalidate_failed_trials!, observer_provenance, describe_backend,
       MISSING_RESPONSE
export model_observer, OBSERVER_CHANNELS, DELIBERATION_LEVELS, run_observer_experiment!,
       observer_summary, print_observer_summary, constant_response

# Method interface (for users adding their own methods)
export initialize_method!, get_next_trial_params, update_method_state!
export is_trial_finished, is_experiment_finished
export apply_method_state!, get_trial_result, revert_method_state!, fresh_instance
export plans_conditions, take_condition!, absorb_operator_trial!, forget_operator_trial!
export method_settings, with_method_settings, steps_on_answers, dependent_settings
export restore_method_state!, draw_further_variables!, adjusted_fields, unset_settings,
       fill_stimulus_settings
export timeout_result, set_task_scored!, answer_score
export planned_trial_count, remaining_trial_count, session_trial_total
export describe_trial, describe_method_state

# Type registries (custom methods/stimuli/engines and extension backends)
export register_method_type!, register_stimulus_type!, register_stimulus!,
       register_engine_type!, register_engine_backend!

# Export API commands
export start_session!, pause!, resume!, abort!, undo_last_trial!, repeat_trial!,
       present_condition!, mark_outlier!, add_comment!
export with_design
export set_fit_gamma!, DEFAULT_FIT_GAMMA, set_feedback!, set_timeout!,
       set_messages!, end_message!,
       set_observer_metadata!, set_task!
export UnitConversion, set_unit_conversion!
export save_session_checkpoint, load_session
export export_session
export generate_session_filename, load_storage_config, load_display_config,
       load_audio_output_device, load_remote_worker_config, load_combining_checks,
       load_control_config, load_input_config, load_rig, user_settings_file,
       resolve_data_dir, resolve_templates_dir,
       PlotOptions, load_plot_options, set_plot_option!
export run_next_trial!, run_experiment!, create_replicated_session,
       replicate_experiment, run_session_from_file
export set_parameters!, check_parameters, selectable_methods, selectable_stimuli, unread_settings
export ScenarioRow, load_scenario, run_scenario!, scenario_state_path
export ScenarioRun, scenario_run_states, prepare_next_run, begin_scenario_run!,
       complete_scenario_run!
export register_participant!, get_participant, list_participants,
       participant_registry_path
export LibraryEntry, browse_sessions, relabel_sessions!
export SessionSeries, browse_series, session_variables
export DISCARDED_DIRECTORY, is_discarded, discard_session, restore_discarded
export on_session_event!, attach_console_reporter!, detach_listener!

# Export Analytics
export AnalysisSet, COMBINING_CHECKS, add_session!, save_analysis_set, load_analysis_set
export AggregatePoint, get_aggregated_data, wilson_interval, print_adjustment_summary
export ReactionTimePoint, reaction_times, print_reaction_times, constant_errors
export DetectionSummary, detection_summary, print_detection_summary
export AdaptiveTrack, adaptive_sequence
export CurveFit, has_interval, curve_value, fit_psychometric_curve, print_psychometric_summary
export PSYCHOMETRIC_FUNCTIONS, psychometric_value

# Operator UI (headless state and text; the window itself is an extension)
export DashboardController, run_when_started!
export ui_label, ui_language, set_ui_language!

# Implemented by extensions (see Core/extension_stubs.jl for load hints)
export plot_psychometric_curve, save_summary_plot, plot_adaptive_sequence
export plot_adjustment_results, save_adjustment_plot
export plot_psychometric_curve!, plot_adjustment_results!
export visualize_results, open_operator_dashboard, install_desktop_icon

# Built-in type registrations (extensions register theirs in their __init__)
foreach(register_method_type!, (ConstantStimuli, Adjustment, Staircase, Psi,
                                Interleaved))
register_stimulus!(MarkerLayout;
    engine = :GeometryVisualEngine,
    backend = [:GLMakie],
    description = "Parametric marker layouts (Oppel-Kundt, Müller-Lyer, length comparisons)")
register_stimulus!(Gabor;
    engine = :GeometryVisualEngine,
    backend = [:GLMakie],
    description = "Two-interval forced-choice Gabor contrast detection")
register_stimulus!(TemporalOppelKundt;
    engine = :AudioStimulusEngine,
    backend = [:PortAudio, :SampledSignals],
    description = "Auditory filled-time and divided-time stimulus")
register_stimulus!(WorkerStimulus; engine = :RemoteEngine)
register_stimulus_type!(BaseStimulusParameters)

foreach(register_engine_type!, (EmulatorEngine, InteractiveEngine, OffscreenVisualEngine,
                                RemoteEngine))

# A session's first psychometric fit compiles the fitting library for seconds. The
# dashboard's live plot fits between trials, on the thread that also times the
# stimulus, so that pause would stretch the next presentation: the fit is compiled
# with the package. Nothing here may read settings or the locale files, whose
# values would be saved into the compiled package.
using PrecompileTools: @compile_workload
@compile_workload begin
    session = SessionContext("precompile", ExperimentParameters("precompile", :level,
                                                                [1.0, 2.0, 3.0], 1),
                             BaseStimulusParameters(1.0), ConstantStimuli())
    for (index, (level, response)) in enumerate(((1.0, 0), (2.0, 1), (3.0, 1)))
        push!(session.history, Trial(index, 0.0, 0.1, [level], response, true))
    end
    points = get_aggregated_data(session)
    source, proportions = psychometric_proportions(points, :auto)
    fit = fit_psychometric_curve(points; gamma = 0.0, on = source)
    [curve_value(fit, level) for level in collect(range(0.9, 3.1; length = 100))]
end

end # module
