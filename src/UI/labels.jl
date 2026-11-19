# Operator-UI text. Headless on purpose: what a panel says about
# a session is decided here and merely displayed by the GLMakie widgets, so the
# wording is unit-tested without a window. The words themselves come from the
# locale files (`ui_label`, locale.jl).

"Shown wherever a session-derived value is requested before a session exists."
no_session_text() = ui_label(:no_session)

"""
    dashboard_participant_text(session) -> String
"""
dashboard_participant_text(::Nothing) = no_session_text()
dashboard_participant_text(session::SessionContext) = session.participant_id

"""
    dashboard_status_text(session) -> String

The session's state, and whether its file has been set aside
([`discard_session`](@ref)): a discarded session keeps the state it stopped in.
"""
dashboard_status_text(::Nothing) = no_session_text()
dashboard_status_text(session::SessionContext) =
    ui_label(Symbol("state_", lowercase(string(session.state)))) *
    (is_discarded(session.save_path) ? ui_label(:discarded_suffix) : "")

"""
    format_dashboard_progress(session) -> String

`"Valid trials: 3 / 12"` when the method knows how many trials it plans,
`"Valid trials: 3"` when it does not (e.g. an open-ended adaptive method).
"""
format_dashboard_progress(::Nothing) = no_session_text()

function format_dashboard_progress(session::SessionContext)
    done = count(t -> t.is_valid, session.history)
    total = planned_valid_trials(session)
    return total === nothing ? ui_label(:progress_open; done) :
                               ui_label(:progress_planned; done, total)
end

"""
    FIT_GAMMA_CHOICES

The lower asymptotes the dashboard offers, as `value => key` pairs. The `Float64`
is the state (`session.fit_gamma`); the key names the text the operator reads
([`fit_gamma_label`](@ref)), which a translation changes without touching the values
it selects.
"""
const FIT_GAMMA_CHOICES = [
    0.0 => :fit_gamma_zero,
    0.5 => :fit_gamma_half,
]

"""
    fit_gamma_label(gamma) -> String

The operator-facing name of a lower asymptote. A value the dashboard does not
offer — one set from a script — is still displayed rather than hidden.
"""
function fit_gamma_label(gamma::Real)
    for (value, key) in FIT_GAMMA_CHOICES
        value == gamma && return ui_label(key)
    end
    return string(gamma)
end

"""
    update_policy_label(policy) -> String

The operator-facing name of a dashboard update policy ([`should_refresh`](@ref)).
"""
update_policy_label(policy::Symbol) = ui_label(Symbol("policy_", policy))

"""
    DashboardPlotSpec

Everything the live results plot needs to label itself. A named specification
rather than a positional tuple: more fields (axis limits, a reference line) are
expected as methods are added, and `spec.y_label` cannot be mixed up the way
`labels[3]` can.
"""
Base.@kwdef struct DashboardPlotSpec
    title::String
    x_label::String
    y_label::String
end

"""
    dashboard_plot_spec(session; converted = true) -> DashboardPlotSpec

Chooses the live plot's labels from the method and the stimulus family: an
adjustment session plots the mean adjusted value, a two-interval auditory
session plots the proportion of "second interval longer" answers, and anything
else plots the mean response. A variable, and an adjusted value, is named by its
unit conversion when the session declares one and `converted` is true.
"""
dashboard_plot_spec(::Nothing; converted::Bool = true) =
    DashboardPlotSpec(title = no_session_text(), x_label = "", y_label = "")

function dashboard_plot_spec(session::SessionContext; converted::Bool = true)
    variable_names = session.ex_par.indep_var_names
    x_label = isempty(variable_names) ? ui_label(:plot_condition) :
              join((converted ? variable_label(session, name) : string(name)
                    for name in variable_names), ", ")

    if session.method_instance isa Adjustment
        y_label = converted ? something(response_label(session), ui_label(:plot_adjustment_y)) :
                              ui_label(:plot_adjustment_y)
        return DashboardPlotSpec(title = ui_label(:plot_adjustment_title), x_label = x_label,
                                 y_label = y_label)
    elseif session.stim_par isa TemporalOppelKundt
        return DashboardPlotSpec(title = ui_label(:plot_psychometric_title),
                                 x_label = x_label, y_label = ui_label(:plot_second_longer_y))
    end
    return DashboardPlotSpec(title = ui_label(:plot_psychometric_title), x_label = x_label,
                             y_label = ui_label(:plot_mean_response_y))
end

# ── Trial table ──────────────────────────────────────────────────────────────

"""
    DashboardTrialRow

One recorded trial as the dashboard's trial table shows it: its number, the
presented value of each of the design's variables, the answer, the local time it
was given, and whether the trial still counts.
"""
Base.@kwdef struct DashboardTrialRow
    trial::Int
    values::Vector{String}
    response::String
    answered_at::String
    counted::Bool
end

"""
    dashboard_trial_headers(session) -> Vector{String}

The trial table's column headers: the trial number, one column per variable of the
design, the answer, its time, and the mark of a trial that no longer counts.
"""
dashboard_trial_headers(::Nothing) = String[]
dashboard_trial_headers(session::SessionContext) =
    [ui_label(:column_trial); string.(session.ex_par.indep_var_names);
     ui_label(:column_response); ui_label(:column_answered); ui_label(:column_mark)]

"""
    dashboard_trial_rows(session) -> Vector{DashboardTrialRow}

Every recorded trial of `session`, in the order presented. The values are the
recorded ones, in the units the stimulus was presented in.
"""
dashboard_trial_rows(::Nothing) = DashboardTrialRow[]
dashboard_trial_rows(session::SessionContext) =
    [DashboardTrialRow(trial = trial.trial_index,
                       values = format_level.(trial.indep_var_vals),
                       response = trial_response_text(trial),
                       answered_at = Libc.strftime("%H:%M:%S", trial.timestamp_response),
                       counted = trial.is_valid)
     for trial in session.history]

"A number as the operator reads it: `800`, not `800.0`."
format_level(x::Integer) = string(x)
format_level(x::Real) = isfinite(x) && isinteger(x) && abs(x) < 1e15 ?
                        string(Int(x)) : string(round(x; sigdigits = 6))

"The answer of one trial, and whether it was right when the task scores it."
function trial_response_text(trial::Trial)
    trial.response === :timeout && return ui_label(:response_timeout)
    answer = format_level(trial.response)
    trial.correct === nothing && return answer
    return answer * " · " * ui_label(trial.correct ? :response_correct : :response_wrong)
end

# ── Response keys ────────────────────────────────────────────────────────────

"""
    response_key_guide(session; label = ui_label) -> Vector{Pair{String, String}}

The response keys — the dashboard window's and a stimulus window's alike — and what each
means in the session's task, as `key => meaning` lines: the arrows adjust in an
adjustment, name an interval in a two-interval task, and answer −1 and +1 otherwise.
`label` gives the text: the interface's language for the dashboard, English for the
console ([`english_label`](@ref)).
"""
function response_key_guide(session::Union{Nothing, SessionContext}; label = ui_label)
    left, right, confirm = label(:key_left), label(:key_right), label(:key_enter_space)
    if session !== nothing && session.method_instance isa Adjustment
        return [left * " / " * right => label(:key_adjust), confirm => label(:key_confirm)]
    elseif session !== nothing && session.stim_par isa TemporalOppelKundt
        return [left => label(:key_first_longer), right => label(:key_second_longer),
                confirm => label(:key_play_again)]
    elseif session !== nothing && session.stim_par isa Gabor
        return [left => label(:key_first_interval), right => label(:key_second_interval),
                confirm => label(:key_show_again)]
    end
    return [left => label(:key_answer; code = "−1"), right => label(:key_answer; code = "+1"),
            confirm => label(:key_answer; code = "0")]
end
