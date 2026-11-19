# What the dashboard's Browse and Parameters views show, decided without a window:
# the setups an operator chooses from, the participants, and the
# parameters of the session in hand. The
# lists read only what `browse_sessions` reads; a file is loaded when it is chosen.

"""
    DashboardEntryRow

One line of the Browse view's lists: the file, its name, and its design, participants,
state, trials and start as the operator reads them. `continuable` marks a session that
was not finished or stopped, which runs on in its own file, `dataset` a combined
dataset, and `id` is a session's own (empty for a dataset).
"""
Base.@kwdef struct DashboardEntryRow
    path::String
    dataset::Bool = false
    id::String = ""
    name::String
    experiment::String
    method::String
    stimulus::String
    participants::String
    state::String
    trials::String
    started::String
    continuable::Bool
end

function dashboard_entry_row(entry::LibraryEntry)
    state = entry.state === nothing ? ui_label(:entry_dataset; count = length(entry.ids)) :
            state_label(entry.state)
    return DashboardEntryRow(
        path = entry.path,
        dataset = entry.kind === :set,
        id = entry.kind === :set ? "" : only(entry.ids),
        name = splitext(basename(entry.path))[1],
        experiment = entry.experiment_name,
        method = entry.method,
        stimulus = entry.stimulus,
        participants = join(entry.participants, ", "),
        state = state,
        trials = trials_text(entry.valid_trials, entry.planned_trials),
        started = started_text(entry.start_time),
        continuable = entry.kind === :session && entry.state in (READY, PAUSED, RUNNING),
    )
end

"""
    dashboard_entry_row(session) -> DashboardEntryRow

The line of a session the dashboard runs, from the session itself: the list gains
it when the session starts, without reading the data directory again during the run.
"""
function dashboard_entry_row(session::SessionContext)
    path = something(session.save_path, "")
    return DashboardEntryRow(
        path = path,
        id = string(session.id),
        name = splitext(basename(path))[1],
        experiment = session.ex_par.experiment_name,
        method = type_name(session.method_instance),
        stimulus = stimulus_name(session.stim_par),
        participants = session.participant_id,
        state = state_label(session.state),
        trials = trials_text(count(t -> t.is_valid, session.history),
                             planned_valid_trials(session)),
        started = started_text(session.start_time),
        continuable = session.state in (READY, PAUSED, RUNNING),
    )
end

state_label(state::SessionState) = ui_label(Symbol("state_", lowercase(string(state))))
trials_text(valid::Int, planned::Union{Nothing, Int}) =
    planned !== nothing ? "$valid / $planned" : valid > 0 ? "$valid" : ""
started_text(time::Union{Nothing, Float64}) =
    time === nothing ? "" : Dates.format(unix2datetime(time), "yyyy-mm-dd HH:MM")

"""
    dashboard_session_participants(rows) -> Vector{String}

The participants the listed sessions name, sorted: the choices of Browse's filter.
"""
dashboard_session_participants(rows::Vector{DashboardEntryRow}) =
    sort!(unique(String[participant for row in rows
                        for participant in split(row.participants, ", ")
                        if !isempty(participant)]))

"""
    filter_session_rows(rows; participant = "", continuable_only = false) -> Vector{DashboardEntryRow}

The listed sessions of one participant (`""` for all), or only those that can be
continued.
"""
filter_session_rows(rows::Vector{DashboardEntryRow}; participant::AbstractString = "",
                    continuable_only::Bool = false) =
    filter(row -> (!continuable_only || row.continuable) &&
                  (isempty(participant) || participant in split(row.participants, ", ")),
           rows)

"""
    dashboard_templates(directory = ".") -> Vector{DashboardEntryRow}

The setups of the templates directory ([`resolve_templates_dir`](@ref)), by name.
"""
dashboard_templates(directory::String = ".") =
    sort!(dashboard_entry_row.(browse_sessions(resolve_templates_dir(directory)));
          by = row -> lowercase(row.name))

"""
    dashboard_previous_sessions(directory = "."; participant = nothing,
                                continuable_only = false) -> Vector{DashboardEntryRow}

The sessions and combined datasets of the data directory, the newest first: those of
one participant, or only the sessions that can be continued.
"""
function dashboard_previous_sessions(directory::String = "."; participant = nothing,
                                     continuable_only::Bool = false)
    rows = dashboard_entry_row.(reverse(browse_sessions(resolve_data_dir(directory);
                                                        participant)))
    return continuable_only ? filter(row -> row.continuable, rows) : rows
end

"""
    dashboard_participants(sessions = DashboardEntryRow[], directory = ".") -> Vector{String}

The participants an operator chooses from: the default one, then, sorted, the registered
ones ([`list_participants`](@ref)) and those the listed sessions name.
"""
dashboard_participants(sessions::Vector{DashboardEntryRow} = DashboardEntryRow[],
                       directory::String = ".") =
    unique([DEFAULT_PARTICIPANT_ID;
            sort!(union(list_participants(; directory),
                        dashboard_session_participants(sessions)))])

"""
    DashboardPlanRow

One scenario plan in the Browse view: the file, its name, how many of its runs are
complete (`runs`), and `next`, the run Start would measure next — or the plan's state
when there is none, and `problem` when the plan or its state file cannot be read.
"""
Base.@kwdef struct DashboardPlanRow
    path::String
    name::String
    runs::String = ""
    next::String
    problem::Bool = false
end

"""
    DashboardRunRow

One run of the chosen plan: its place in the plan, id, participant, the setup it
replicates, the file it is written to, and its state ([`scenario_run_states`](@ref)).
"""
Base.@kwdef struct DashboardRunRow
    position::String
    id::String
    participant::String
    setup::String
    file::String
    state::String
end

"""
    dashboard_plans(directory = ".") -> Vector{DashboardPlanRow}

The scenario plans of the templates directory ([`resolve_templates_dir`](@ref)) — its
`.toml` files, a plan's state file aside — by name.
"""
function dashboard_plans(directory::String = ".")
    folder = resolve_templates_dir(directory)
    paths = filter(path -> endswith(lowercase(path), ".toml") &&
                           !endswith(lowercase(path), ".state.toml") && isfile(path),
                   abspath.(readdir(folder; join = true)))
    return sort!(dashboard_plan_row.(paths); by = row -> lowercase(row.name))
end

function dashboard_plan_row(path::String)
    name = splitext(basename(path))[1]
    runs = try
        scenario_run_states(path)
    catch
        return DashboardPlanRow(; path, name, next = ui_label(:plan_unreadable), problem = true)
    end
    complete = count(run -> run.second === :complete, runs)
    index = findfirst(run -> run.second !== :complete, runs)
    return DashboardPlanRow(; path, name, runs = "$complete / $(length(runs))",
                            next = index === nothing ? ui_label(:plan_complete) :
                                                       runs[index].first.id)
end

"""
    dashboard_plan_runs(plan_path) -> Vector{DashboardRunRow}

The runs of a scenario plan with their states; none when the plan cannot be read.
"""
function dashboard_plan_runs(plan_path::AbstractString)
    states = try
        scenario_run_states(plan_path)
    catch
        return DashboardRunRow[]
    end
    return [DashboardRunRow(position = string(position), id = row.id,
                            participant = row.participant_id,
                            setup = splitext(basename(row.source))[1],
                            file = basename(row.destination),
                            state = ui_label(Symbol("run_", state)))
            for (position, (row, state)) in enumerate(states)]
end

"""
    ParameterRow

One line of the Parameters view: `key`, what an edit of the line sets
([`edit_dashboard_parameter!`](@ref) or [`edit_ticked_labels!`](@ref)), or `nothing` for
a line that is not edited; the `label`; the `value` as shown; `edit`, the text an edit
field starts from, in full; `choices`, as `shown => text` pairs, for a line chosen from a
list; `unset` for a method setting still to be given ([`unset_settings`](@ref)) or a
project unit entry the start would refuse; `differs` when ticked sessions disagree on
this line; `tooltip`, what the line shows of its value when pointed at; and `source`,
the settings file a project's entry comes from, or `nothing`.
"""
Base.@kwdef struct ParameterRow
    key::Union{Nothing, String} = nothing
    label::String
    value::String
    edit::String = value
    choices::Vector{Pair{String, String}} = Pair{String, String}[]
    unset::Bool = false
    differs::Bool = false
    tooltip::Union{Nothing, String} = nothing
    source::Union{Nothing, String} = nothing
end

# What the Stimulus line shows when pointed at: the stimulus's description, the engine the
# session is presented by, and the program recorded as presenting it, with its version
function stimulus_tooltip(session::SessionContext)
    lines = String[]
    description = stimulus_description(session.stim_par)
    isempty(description) || push!(lines, description)
    push!(lines, ui_label(:tooltip_engine; engine = session.engine_name))
    recorded = presenting_stimulus(session.environment)
    recorded === nothing ||
        push!(lines, ui_label(:tooltip_recorded_program; program = identity_text(recorded)))
    stated = get(session.environment, "stimulus_version_stated", nothing)
    stated === nothing ||
        push!(lines, ui_label(:tooltip_stated_version; version = stated))
    return join(lines, "\n")
end

"""
    dashboard_setup_rows(session; declared = nothing) -> NamedTuple

The parameters of a session, as the Parameters view's three tables show them:
`experiment`, the settings, `stimulus`, every stimulus parameter, and `messages`, what
the participant is shown between trials, each a [`ParameterRow`](@ref). A parameter a
variable of the design sets, or the method adjusts, is listed as such, and is not edited
there. Rows are read from the session itself, so they describe what Start runs.
"""
function dashboard_setup_rows(session::SessionContext; declared = nothing)
    ex_par = session.ex_par
    method = session.method_instance
    experiment = ParameterRow[
        ParameterRow(key = "ex_par.experiment_name", label = ui_label(:setup_experiment),
                     value = ex_par.experiment_name),
        ParameterRow(key = "method", label = ui_label(:setup_method), value = type_name(method),
                     choices = [name => name for name in selectable_methods()]),
    ]
    settings = method_settings(method)
    dependent = dependent_settings(method)
    unset = unset_settings(method)
    if isempty(settings)
        # A method that names no settings shows how it differs from its default
        for (field, value) in differing_fields(method)
            push!(experiment, ParameterRow(label = "    $field", value = format_setting(value)))
        end
    end
    for (name, value) in settings
        name in dependent && continue
        push!(experiment, setting_row(name, value; unset = name in unset))
    end

    # The independent variables, each a stimulus parameter chosen from a list, with its
    # levels; the first is the plot's x axis and the one an adaptive method moves
    candidates = variable_candidates(session)
    for (index, (name, range)) in enumerate(zip(ex_par.indep_var_names, ex_par.indep_var_ranges))
        choices = [string(name) => string(name); [field => field for field in candidates]]
        length(ex_par.indep_var_names) > 1 && push!(choices, ui_label(:remove_variable) => "")
        push!(experiment, ParameterRow(key = "variable.$index", choices = choices,
                                       label = index == 1 ? ui_label(:setup_independent) :
                                               ui_label(:setup_independent_more; number = index),
                                       value = string(name)))
        push!(experiment, ParameterRow(key = "levels.$name", label = "    " * ui_label(:setup_levels),
                                       value = format_setting(range),
                                       edit = setting_edit_text(range)))
    end
    isempty(candidates) || push!(experiment, ParameterRow(
        key = "variable.new", label = ui_label(:add_variable), value = "",
        choices = [field => field for field in candidates]))

    # The dependent variable: a stimulus parameter the method sets, or the answer
    if !isempty(dependent)
        fields = numeric_fields(session.stim_par)
        settings_by_name = Dict(settings)
        variable = dependent[1]
        value = settings_by_name[variable]
        current = value === nothing ? "" : string(value)
        offered = filter(f -> !(Symbol(f) in ex_par.indep_var_names), fields)
        push!(experiment, ParameterRow(
            key = "method.$variable", label = ui_label(:setup_dependent), value = current,
            choices = [field => field for field in unique(filter(!isempty, [current; offered]))],
            unset = variable in unset))
        for name in dependent[2:end]
            push!(experiment, setting_row(name, settings_by_name[name]; unset = name in unset))
        end
    else
        push!(experiment, ParameterRow(label = ui_label(:setup_dependent),
                                       value = ui_label(answers_scored(session) ?
                                                        :measure_correct : :measure_answers)))
        push!(experiment, ParameterRow(key = "task", label = ui_label(:setup_task),
                                       value = fit_gamma_label(session.fit_gamma),
                                       choices = [fit_gamma_label(value) => string(value)
                                                  for (value, _) in FIT_GAMMA_CHOICES]))
    end
    push!(experiment, ParameterRow(key = "ex_par.repeats", label = ui_label(:setup_repeats),
                                   value = string(ex_par.repeats)))
    # The stimulus in hand is listed whether or not it can be chosen again: a worker's
    # stimulus stays when its worker is not connected
    current = stimulus_name(session.stim_par)
    push!(experiment, ParameterRow(
        key = "stimulus", label = ui_label(:setup_stimulus), value = current,
        choices = [name => name
                   for name in sort!(unique!([current; selectable_stimuli(; declared)]))],
        tooltip = stimulus_tooltip(session)))
    push!(experiment, ParameterRow(key = "tags", label = ui_label(:setup_tags),
                                   value = join(session.tags, ", ")))
    push!(experiment, ParameterRow(key = "feedback", label = ui_label(:setup_feedback),
                                   value = ui_label(session.feedback ? :yes : :no),
                                   edit = session.feedback ? "yes" : "no"))
    push!(experiment, ParameterRow(key = "timeout_s", label = ui_label(:setup_timeout),
                                   value = session.timeout_s === nothing ?
                                           ui_label(:setup_no_timeout) :
                                           ui_label(:setup_seconds;
                                                    seconds = format_level(session.timeout_s)),
                                   edit = session.timeout_s === nothing ? "" :
                                          setting_edit_text(session.timeout_s)))
    # Before the start, a variable with no conversion of its own shows the project's
    # entry, which the start takes (`resolve_session_unit_conversions`)
    defaults = session.state == READY ?
               read_settings_section(".", UNITS_SECTION_PREFIX * current) : nothing
    for variable in convertible_variables(session)
        key, label = "units.$variable", ui_label(:setup_units; variable = string(variable))
        conversion = get(session.unit_conversions, variable, nothing)
        push!(experiment,
              conversion !== nothing ?
                  ParameterRow(; key, label, value = conversion.label,
                               edit = conversion_formula(variable, conversion)) :
              defaults === nothing || !haskey(defaults.values, string(variable)) ?
                  ParameterRow(; key, label, value = "—", edit = "") :
                  project_units_row(session, variable, key, label, defaults))
    end

    # Every stimulus parameter, as the project author decided: a list of those that
    # differ from the type's default hid a value set on purpose to the default
    stim_par = session.stim_par
    adjusted = adjusted_fields(method)
    stimulus = ParameterRow[]
    for name in parameter_names(stim_par)
        value = parameter_value(stim_par, name)
        if name in ex_par.indep_var_names || name in adjusted
            # Set by the design or the method during the session; the line holds the
            # value a preview presents (`preview_condition`)
            index = findfirst(==(name), ex_par.indep_var_names)
            preview = index === nothing ? value : first(ex_par.indep_var_ranges[index])
            push!(stimulus, ParameterRow(key = "preview.$name", label = string(name),
                                         value = ui_label(name in adjusted ? :set_by_method :
                                                                             :set_by_design),
                                         edit = setting_edit_text(preview)))
        else
            push!(stimulus, ParameterRow(key = "stim_par.$name", label = string(name),
                                         value = format_setting(value),
                                         edit = setting_edit_text(value)))
        end
    end

    msgs = session.messages
    instructions_row = if session.task === nothing
        ParameterRow(label = ui_label(:setup_instructions),
                     value = ui_label(:setup_no_task))
    else
        ParameterRow(key = "messages.instructions", label = ui_label(:setup_instructions),
                     value = ui_label(msgs.instructions ? :yes : :no),
                     edit = msgs.instructions ? "yes" : "no")
    end

    break_every = msgs.break_every
    break_every_row = ParameterRow(
        key = "messages.break_every",
        label = ui_label(:setup_break_every),
        value = break_every == 0 ? ui_label(:setup_no_breaks) : string(break_every),
        edit = break_every == 0 ? "" : string(break_every),
    )

    break_after = msgs.break_after
    break_after_row = ParameterRow(
        key = "messages.break_after",
        label = ui_label(:setup_break_after),
        value = isempty(break_after) ? "—" : join(break_after, ", "),
        edit = isempty(break_after) ? "" : setting_edit_text(break_after),
    )

    waits_for = msgs.break_waits_for
    break_waits_row = ParameterRow(
        key = "messages.break_waits_for",
        label = ui_label(:setup_break_waits_for),
        value = waits_for === :operator ? ui_label(:waits_for_operator) :
                                          ui_label(:waits_for_participant),
        choices = [ui_label(:waits_for_participant) => "participant",
                   ui_label(:waits_for_operator) => "operator"],
    )

    break_min_s = msgs.break_min_s
    break_min_row = ParameterRow(
        key = "messages.break_min_s",
        label = ui_label(:setup_break_min),
        value = ui_label(:setup_seconds; seconds = format_level(break_min_s)),
        edit = setting_edit_text(break_min_s),
    )

    break_text_row = ParameterRow(
        key = "messages.break_text",
        label = ui_label(:setup_break_text),
        value = msgs.break_text,
        edit = msgs.break_text,
    )

    closing_text = msgs.closing_text
    closing_text_row = ParameterRow(
        key = "messages.closing_text",
        label = ui_label(:setup_closing_text),
        value = isempty(closing_text) ? "—" : closing_text,
        edit = closing_text,
    )

    messages = ParameterRow[
        instructions_row,
        break_every_row,
        break_after_row,
        break_waits_row,
        break_min_row,
        break_text_row,
        closing_text_row,
    ]

    return (experiment = experiment, stimulus = stimulus, messages = messages)
end

# The configuration a method was given: the fields in which a fresh instance of it
# differs from a method built with no arguments. A session that has run carries run
# state besides, which `fresh_instance` leaves out.
function differing_fields(method::AbstractPsychoMethod)
    configured, default = try
        fresh_instance(method), typeof(method)()
    catch
        return Pair{Symbol, Any}[]
    end
    return Pair{Symbol, Any}[name => getfield(configured, name)
                             for name in fieldnames(typeof(method))
                             if !isequal(getfield(configured, name), getfield(default, name))]
end

"A setting's value as the operator reads it; a long list is shortened."
format_setting(value::Real) = format_level(value)
format_setting(value::Bool) = ui_label(value ? :yes : :no)
format_setting(value::AbstractString) = String(value)
format_setting(value::Symbol) = string(value)
format_setting(::Nothing) = "—"
format_setting(value::AbstractPsychoMethod) = type_name(value)
format_setting(value::AbstractRange{<:Real}) = length(value) <= 1 ?
    join(format_level.(value), ", ") :
    "$(format_level(first(value))) : $(format_level(step(value))) : $(format_level(last(value)))"

function format_setting(value::Union{Tuple, AbstractVector})
    items = [format_setting(item) for item in value]
    length(items) <= 8 && return join(items, ", ")
    return join(items[1:3], ", ") * ", …, " * last(items) * "  (" *
           ui_label(:setup_values; count = length(items)) * ")"
end

function format_setting(value)
    text = repr(value)
    return length(text) <= 60 ? text : first(text, 57) * "…"
end

# ── Editing ──────────────────────────────────────────────────────────────────

"""
    setting_edit_text(value) -> String

A value as an edit field shows it, in full, so that the text read back
([`parse_setting_text`](@ref)) is the value again: every number to its last digit, and
evenly spaced levels as `first:step:last`.
"""
setting_edit_text(value::Bool) = value ? "true" : "false"
setting_edit_text(value::Integer) = string(value)
setting_edit_text(value::Real) =
    isfinite(value) && isinteger(value) && abs(value) < 1e15 ? string(Int(value)) : string(value)
setting_edit_text(value::AbstractString) = String(value)
setting_edit_text(value::Symbol) = string(value)
setting_edit_text(::Nothing) = ""

function setting_edit_text(value::Union{Tuple, AbstractVector})
    items = collect(value)
    if length(items) >= 3 && all(item -> item isa Real && !(item isa Bool), items)
        step = items[2] - items[1]
        spaced = step != 0 && collect(range(items[1]; step, length = length(items))) == items
        spaced && return join(setting_edit_text.(step == 1 ? (items[1], items[end]) :
                                                 (items[1], step, items[end])), ":")
    end
    return join(setting_edit_text.(items), ", ")
end

setting_edit_text(value) = repr(value)

"""
    parse_setting_text(text) -> value

What an operator typed, as a session file writes a value: nothing for an empty field,
a whole number, a number, `true` or `false`, a list of values separated by commas,
`first:last` or `first:step:last` for evenly spaced numbers — inside a list too — and
the text itself otherwise. The parameter's type decides what is accepted
([`set_parameters!`](@ref)).
"""
function parse_setting_text(text::AbstractString)
    text = strip(text)
    isempty(text) && return nothing
    occursin(',', text) || return parse_setting_item(text)
    items = Any[]
    for part in split(text, ',')
        item = parse_setting_item(strip(part))
        item isa AbstractVector ? append!(items, item) : push!(items, item)
    end
    return items
end

function parse_setting_item(text::AbstractString)
    parts = split(text, ':')
    if 2 <= length(parts) <= 3
        numbers = [parse_setting_number(strip(part)) for part in parts]
        all(!isnothing, numbers) && return collect(length(numbers) == 2 ?
                                                   (numbers[1]:numbers[2]) :
                                                   (numbers[1]:numbers[2]:numbers[3]))
    end
    number = parse_setting_number(text)
    number === nothing || return number
    lowercase(text) in ("true", "yes") && return true
    lowercase(text) in ("false", "no") && return false
    return String(text)
end

parse_setting_number(text::AbstractString) =
    something(tryparse(Int, text), tryparse(Float64, text), Some(nothing))

# The text of a field as the value its type takes: a text field keeps it as typed,
# a list field takes a single value as a list of one
function raw_setting(T::Type, text::AbstractString)
    optional = T isa Union && Nothing <: T
    inner = optional ? (T.a === Nothing ? T.b : T.a) : T
    optional && isempty(strip(text)) && return nothing
    inner <: AbstractString && return String(text)
    inner <: Symbol && return String(strip(text))
    value = parse_setting_text(text)
    inner <: Union{Tuple, AbstractVector} && value !== nothing && !(value isa AbstractVector) &&
        return Any[value]
    return value
end

# A method setting's text as the value its constructor takes: a name stays as typed, a
# list setting takes a single value as a list of one
function method_setting_raw(current, text::AbstractString)
    current isa Union{Symbol, AbstractString} && return String(strip(text))
    value = parse_setting_text(text)
    current isa Union{Tuple, AbstractVector} && value !== nothing &&
        !(value isa AbstractVector) && return Any[value]
    return value
end

# The project's `[units.<stimulus>]` entry for `variable`, resolved with the rig's
# constants as the start will resolve it; one the start would refuse is marked, with
# the reason
function project_units_row(session::SessionContext, variable::Symbol, key::String,
                           label::String, defaults::SettingsSection)
    name = string(variable)
    source = defaults.sources[name]
    shown = string(defaults.values[name])
    tip = ui_label(:settings_from_file; path = source)
    try
        text = section_setting(defaults, name)
        conversion = parse_session_unit_conversion(session, variable, text, load_rig())
        conversion === nothing && return ParameterRow(; key, label, value = "—", edit = "")
        check_unit_conversion(session, variable, conversion)
        return ParameterRow(; key, label, value = conversion.label, edit = text,
                            tooltip = tip, source)
    catch err
        err isa ArgumentError || rethrow()
        return ParameterRow(; key, label, value = shown, edit = shown, unset = true,
                            tooltip = tip * "\n" * err.msg, source)
    end
end

setting_row(name::Symbol, value; unset::Bool = false) =
    ParameterRow(key = "method.$name", label = "    $name", value = format_setting(value),
                 edit = setting_edit_text(value), unset = unset)

# The stimulus parameters that hold a number, by name
numeric_fields(stim_par::AbstractStimulusParameters) = string.(numeric_parameters(stim_par))

# The stimulus parameters a variable can be made of: those holding a number that are
# neither a variable already nor set by the method
function variable_candidates(session::SessionContext)
    taken = Set([session.ex_par.indep_var_names; adjusted_fields(session.method_instance)])
    return [field for field in numeric_fields(session.stim_par) if !(Symbol(field) in taken)]
end

# Whether the stimulus declares a correct answer, so that the measure is the
# proportion correct (`psychometric_proportions`), read at the design's first condition
function answers_scored(session::SessionContext)
    ranges = session.ex_par.indep_var_ranges
    (isempty(ranges) || any(isempty, ranges)) && return false
    first_condition = Float64[first(levels) for levels in ranges]
    return correct_answer(session.stim_par,
                          trial_variables(session.ex_par, first_condition)) !== nothing
end

"""
    preview_condition(session, values::AbstractDict) -> (stim_par, vals)

The stimulus a preview presents ([`preview_stimulus`](@ref)), and the values of the
design's variables for it: each variable at the value `values` gives under its name —
text as the operator typed it — or at its first level; a parameter the method sets at
the value given, or at the one it holds. The session is not changed. A value that is
not a number, or a stimulus that cannot be presented ([`validate_stimulus`](@ref)), is
refused with an `ArgumentError`.
"""
function preview_condition(session::SessionContext, values::AbstractDict)
    stimulus = deepcopy(session.stim_par)
    number(name, fallback) = begin
        text = get(values, string(name), nothing)
        value = text === nothing ? fallback : parse_setting_text(text)
        value isa Real && !(value isa Bool) || throw(ArgumentError(
            "The preview value of $name is a number, got $(repr(something(text, value)))."))
        value
    end
    names = session.ex_par.indep_var_names
    vals = Float64[number(name, first(levels))
                   for (name, levels) in zip(names, session.ex_par.indep_var_ranges)]
    try
        apply_variables!(stimulus, names, vals)
        for field in adjusted_fields(session.method_instance)
            has_parameter(stimulus, field) &&
                set_converted!(stimulus, field, number(field, parameter_value(stimulus, field)))
        end
    catch err
        err isa Union{InexactError, MethodError} || rethrow()
        throw(ArgumentError("A preview value does not fit its parameter: " *
                            sprint(showerror, err)))
    end
    validate_stimulus(stimulus)
    return stimulus, vals
end
