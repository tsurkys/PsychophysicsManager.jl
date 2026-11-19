# Dear ImGui extension: the operator dashboard. Loads when CImGui,
# ImPlot, GLFW and ModernGL are loaded; CImGui needs the last two for its own
# GLFW/OpenGL backend anyway.
#
# Everything the dashboard decides — which actions are available, what the panel
# says, what the live plot draws, who owns the engine — is the headless
# `DashboardController` and the text and plot functions of `src/UI/`. The
# files here only place widgets and forward what the operator does:
#
#   widgets.jl   text, tooltips, buttons and colours shared by the views
#   window.jl    the window: its render loop, scale, font, layout, menu bar, and
#                the response keys it forwards
#   views.jl     the views docked in it: browse, parameters, control, live plot,
#                trials, settings, messages
#
# A GLMakie stimulus window may share the process, the main thread and OpenGL
# with this one. The dashboard keeps that working by never waiting for the
# display's vertical sync (`window.jl`) and by drawing only inside its frame.

module PsychophysicsManagerImGuiExt

using PsychophysicsManager
import PsychophysicsManager: open_operator_dashboard
using PsychophysicsManager: DashboardController, SessionContext, AggregatePoint, action_state,
                 bind_session!, close_controller!, install_response_source!,
                 ChannelResponseSource, offer_response!, shown_message, READY, RUNNING, PAUSED,
                 FINISHED, ABORTED,
                 dashboard_participant_text, dashboard_status_text,
                 format_dashboard_progress, planned_valid_trials,
                 dashboard_plot_series, DashboardPlotSeries, DashboardTrialPoint,
                 DashboardPlotSpec, PROPORTION_LIMITS,
                 PlotOptions, PLOT_SPREADS, PLOT_SPLITS,
                 settings_plot_options, set_dashboard_plot_option!,
                 DashboardPlotLine, DashboardDataPlot, DataViewRow, SessionCache,
                 is_live_plot_mode, load_ticked_data_view, earlier_sessions_line,
                 data_view_rows, prune_session_cache!,
                 dashboard_point_trials,
                 dashboard_trial_headers, dashboard_trial_rows, DashboardTrialRow,
                 response_key_guide, trial_response_text, format_level,
                 start_experiment!, pause_experiment!, end_dashboard_message!,
                 resume_experiment!, undo_dashboard_trial!, stop_experiment!,
                 discard_dashboard_file!, mark_dashboard_outlier!, repeat_dashboard_trial!,
                 add_dashboard_comment!, close_dashboard!,
                 add_dashboard_trial!, present_dashboard_condition!, can_present,
                 dashboard_point_condition, dashboard_design_conditions, trial_actions,
                 UPDATE_POLICIES, update_policy_label,
                 set_update_policy!, dashboard_monitor_index, SessionState,
                 DashboardEntryRow, dashboard_templates,
                 dashboard_participants, dashboard_setup_rows, choose_setup!,
                 set_dashboard_participant!, open_previous_session!,
                 start_new_session!, control_buttons, no_session_text,
                 LibraryEntry, DashboardFilters, DashboardSeriesRow, state_label,
                 parse_filter_date, parse_filter_parameter,
                 dashboard_entry_experiments, dashboard_entry_participants,
                 dashboard_entry_methods, dashboard_entry_stimuli,
                 dashboard_series_rows, dashboard_dataset_rows, session_library_entry,
                 reread_library!, tick_session!, tick_series!, series_tick_state,
                 clear_ticks!, choose_series!,
                 ParameterRow, can_edit_parameters, can_edit_reporting, reporting_key,
                 edit_dashboard_parameter!, connected_engine, stimulus_name,
                 selectable_methods, can_preview, preview_dashboard_stimulus!, preview_open,
                 close_preview!,
                 prepared_session, parameters_session, after_setting_aside!,
                 save_dashboard_template!, resolve_templates_dir, resolve_data_dir,
                 is_running, paused_loop, set_message!,
                 DashboardPlanRow, DashboardRunRow, dashboard_plans, dashboard_plan_runs,
                 choose_scenario!, prepare_next_scenario_run!, can_choose_participant,
                 keyboard_control, continue_changed_stimulus!,
                 COMBINING_CHECKS, set_combining_check!, save_ticked_dataset!,
                 ticked_parameter_rows, edit_ticked_labels!,
                 SettingsSectionRows, SettingRow, dashboard_settings, settings_targets,
                 user_settings_file,
                 unread_settings_text,
                 edit_dashboard_setting!, reset_dashboard_setting!,
                 ControlChannel, start_control_channel_from_settings, stop_control_channel!,
                 window_icon_images, DESKTOP_WINDOW_CLASS, DESKTOP_APP_ID
import CImGui as ig
import ImPlot
import GLFW
import ModernGL

include("widgets.jl")
include("window.jl")
include("views.jl")

function __init__()
    atexit(close_dashboard_at_exit)
    use_system_cursor_themes!()
    return nothing
end

# GLFW takes its mouse cursors from the desktop's cursor theme through libXcursor. The
# libXcursor Julia's artifacts bring looks for themes under the prefix it was built in
# (/workspace/destdir/share/icons), finds none, and GLFW falls back to the X core font's
# cursor, which nothing enlarges on a HiDPI display. Unless the user has chosen a path,
# it is given the one a system's own libXcursor searches. It reads the variable once,
# when a cursor is first made, so this runs before the dashboard's window exists.
function use_system_cursor_themes!()
    (Sys.islinux() || Sys.isbsd()) && !haskey(ENV, "XCURSOR_PATH") &&
        (ENV["XCURSOR_PATH"] = "~/.local/share/icons:~/.icons:/usr/share/icons:/usr/share/pixmaps")
    return nothing
end

end # module
