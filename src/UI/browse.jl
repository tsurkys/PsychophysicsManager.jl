# Headless model for Browse's Sessions tab (filters, series, datasets, ticks)
# and for Parameters over several ticked sessions. All filtering and grouping run
# in memory on the LibraryEntries last read from disk.

"""
    DashboardFilters

Filter state of Browse's Sessions tab: exact `experiment`, `participant`, `method`, and
`stimulus` (`""` = all), comma-separated `tags` (all must be present), `state` (`:all`,
`:continuable` for READY/PAUSED/RUNNING, or one [`SessionState`](@ref)), free `text`,
`from` and `to` dates (`yyyy-mm-dd`, empty = open; malformed text is ignored), and
`parameter` (`name = value`, empty = none).
"""
Base.@kwdef mutable struct DashboardFilters
    experiment::String = ""
    participant::String = ""
    tags::String = ""
    state::Union{Symbol, SessionState} = :all
    text::String = ""
    method::String = ""
    stimulus::String = ""
    from::String = ""
    to::String = ""
    parameter::String = ""
end

"""
    parse_filter_date(text) -> (Union{Nothing, Date}, Bool)

Parses a `yyyy-mm-dd` filter bound. Empty text returns `(nothing, true)`; malformed text
returns `(nothing, false)` so filtering ignores it while the field is marked.
"""
function parse_filter_date(text::AbstractString)
    trimmed = strip(text)
    isempty(trimmed) && return (nothing, true)
    occursin(r"^\d{4}-\d{2}-\d{2}$", trimmed) || return (nothing, false)
    parsed = tryparse(Date, trimmed, dateformat"yyyy-mm-dd")
    return parsed === nothing ? (nothing, false) : (parsed, true)
end

"""
    parse_filter_parameter(text) -> (Union{Nothing, Pair{Symbol, Any}}, Bool)

Parses a `name = value` parameter filter. Empty text returns `(nothing, true)`; malformed
text returns `(nothing, false)`.
"""
function parse_filter_parameter(text::AbstractString)
    trimmed = strip(text)
    isempty(trimmed) && return (nothing, true)
    eq = findfirst('=', trimmed)
    eq === nothing && return (nothing, false)
    raw_name = strip(trimmed[1:prevind(trimmed, eq)])
    raw_value = strip(trimmed[nextind(trimmed, eq):end])
    (isempty(raw_name) || isempty(raw_value)) && return (nothing, false)
    return (Symbol(raw_name) => parse_setting_text(raw_value), true)
end

"""
    filtered_entries(entries, filters) -> Vector{LibraryEntry}

Applies `filters` to `entries` in memory by mapping them onto [`filter_entries`](@ref).
"""
function filtered_entries(entries::AbstractVector{LibraryEntry},
                          filters::DashboardFilters = DashboardFilters())
    (filters.state isa SessionState || filters.state in (:all, :continuable)) ||
        throw(ArgumentError("Unknown state filter $(repr(filters.state))."))
    from_date, _ = parse_filter_date(filters.from)
    to_date, _ = parse_filter_date(filters.to)
    param_pair, _ = parse_filter_parameter(filters.parameter)
    tag_list = String[String(strip(t)) for t in split(filters.tags, ',') if !isempty(strip(t))]

    kept = filter_entries(
        entries;
        participant = isempty(filters.participant) ? nothing : filters.participant,
        experiment = isempty(filters.experiment) ? nothing : filters.experiment,
        tags = isempty(tag_list) ? nothing : tag_list,
        method = isempty(filters.method) ? nothing : filters.method,
        stimulus = isempty(filters.stimulus) ? nothing : filters.stimulus,
        state = filters.state isa SessionState ? filters.state : nothing,
        from = from_date,
        to = to_date,
        parameter = param_pair,
        text = isempty(strip(filters.text)) ? nothing : strip(filters.text),
    )
    if filters.state === :continuable
        return LibraryEntry[e for e in kept
                            if e.kind === :session && e.state in (READY, PAUSED, RUNNING)]
    end
    return kept
end

dashboard_entry_experiments(entries::AbstractVector{LibraryEntry}) =
    sort!(unique(String[e.experiment_name for e in entries if !isempty(e.experiment_name)]))

dashboard_entry_participants(entries::AbstractVector{LibraryEntry}) =
    sort!(unique(String[p for e in entries for p in e.participants if !isempty(p)]))

dashboard_entry_methods(entries::AbstractVector{LibraryEntry}) =
    sort!(unique(String[e.method for e in entries if !isempty(e.method)]))

dashboard_entry_stimuli(entries::AbstractVector{LibraryEntry}) =
    sort!(unique(String[e.stimulus for e in entries if !isempty(e.stimulus)]))

dashboard_participants(entries::AbstractVector{LibraryEntry}, directory::String = ".") =
    unique([DEFAULT_PARTICIPANT_ID;
            sort!(union(list_participants(; directory),
                        dashboard_entry_participants(entries)))])

"""
    session_library_entry(session) -> LibraryEntry

Builds a [`LibraryEntry`](@ref) from an in-memory session so a newly started run can be
listed in Browse without reading the data directory during the run.
"""
function session_library_entry(session::SessionContext)
    path = something(session.save_path, "")
    return LibraryEntry(
        path,
        :session,
        String[string(session.id)],
        String[session.participant_id],
        copy(session.tags),
        session.ex_par.experiment_name,
        type_name(session.method_instance),
        stimulus_name(session.stim_par),
        copy(session.ex_par.indep_var_names),
        session.state,
        session.start_time,
        length(session.history),
        count(t -> t.is_valid, session.history),
        planned_valid_trials(session),
        String[c.text for c in session.comments],
        Dict{Symbol, Any}(name => fact_value(parameter_value(session.stim_par, name))
                          for name in parameter_names(session.stim_par)),
        Dict{Symbol, Vector{Any}}(name => Any[fact_value(v) for v in range]
                                  for (name, range) in zip(session.ex_par.indep_var_names,
                                                           session.ex_par.indep_var_ranges)),
        session_facts(session, COMBINING_CHECKS),
    )
end

# ── Series and dataset rows ──────────────────────────────────────────────────

"""
    DashboardSeriesRow

One series line in Browse's Sessions tab: `key` (path of its first session, stable across
rereads), `participant`, `experiment`, `variables` (session variables distinguishing it
from other shown series of the same experiment), `repetitions`, `trials` (valid of planned, summed),
`last_run`, `state` of the latest session, `continuable`, and `sessions` (oldest first).
"""
Base.@kwdef struct DashboardSeriesRow
    key::String
    participant::String
    experiment::String
    variables::String
    repetitions::Int
    trials::String
    last_run::String
    state::String
    continuable::Bool
    sessions::Vector{DashboardEntryRow}
end

function format_series_fact(fact::Symbol, val)
    if fact === :stimulus_type
        return val isa AbstractVector && length(val) >= 2 ? string(val[2]) : format_setting(val)
    elseif fact === :method
        return val isa AbstractVector ? join(val, "/") : format_setting(val)
    elseif fact === :fit_gamma
        return val isa Real ? fit_gamma_label(val) : format_setting(val)
    elseif fact === :timeout
        return val === nothing ? ui_label(:setup_no_timeout) :
               ui_label(:setup_seconds; seconds = format_level(val))
    elseif fact === :instructions
        val === nothing && return "—"
        s = string(val)
        return length(s) <= 30 ? s : first(s, 27) * "…"
    elseif fact === :units
        val isa AbstractDict || return format_setting(val)
        isempty(val) && return "—"
        return join(("$k: $v" for (k, v) in sort!(collect(val); by = first)), ", ")
    elseif fact === :observer
        val isa AbstractDict || return format_setting(val)
        isempty(val) && return "—"
        return join(("$k=$v" for (k, v) in sort!(collect(val); by = first)), ", ")
    end
    return format_setting(val)
end

function series_variables_text(series::SessionSeries, vars)
    parts = String[]
    stim = find_series_fact(series, :stimulus)
    stimulus_differs = :stimulus_type in vars.other
    for param in vars.parameters
        val = stim isa AbstractDict ? get(stim, string(param), ABSENT) : ABSENT
        if val !== ABSENT
            push!(parts, "$param = $(format_setting(val))")
        elseif !stimulus_differs
            push!(parts, "$param = —")
        end
    end
    for tag_key in vars.tags
        haskey(series.tag_values, tag_key) &&
            push!(parts, "$tag_key:$(series.tag_values[tag_key])")
    end
    for fact in vars.other
        val = find_series_fact(series, fact)
        val === ABSENT && continue
        push!(parts, "$(ui_label(Symbol("fact_", fact))) = $(format_series_fact(fact, val))")
    end
    return join(parts, ", ")
end

"""
    dashboard_series_rows(entries, filters = DashboardFilters(),
                          checks = COMBINING_CHECKS) -> Vector{DashboardSeriesRow}

Filters `entries` and groups their sessions into [`DashboardSeriesRow`](@ref)s under
`checks`, newest last run first (never-started series last). Combined datasets are
omitted (see [`dashboard_dataset_rows`](@ref)).
"""
function dashboard_series_rows(entries::AbstractVector{LibraryEntry},
                               filters::DashboardFilters = DashboardFilters(),
                               checks = COMBINING_CHECKS)
    kept = filtered_entries(entries, filters)
    grouped = group_series(kept; checks)
    isempty(grouped) && return DashboardSeriesRow[]

    by_exp = Dict{String, Vector{SessionSeries}}()
    for s in grouped
        push!(get!(by_exp, s.experiment_name, SessionSeries[]), s)
    end
    vars_by_exp = Dict(exp => session_variables(list) for (exp, list) in by_exp)

    rows_with_time = Tuple{Union{Nothing, Float64}, DashboardSeriesRow}[]
    for s in grouped
        session_rows = dashboard_entry_row.(s.entries)
        started_times = Float64[e.start_time for e in s.entries if e.start_time !== nothing]
        latest_time = isempty(started_times) ? nothing : maximum(started_times)
        valid = sum(e -> e.valid_trials, s.entries; init = 0)
        planned = any(e -> e.planned_trials === nothing, s.entries) ? nothing :
                  sum(e -> e.planned_trials, s.entries)
        row = DashboardSeriesRow(
            key = first(s.entries).path,
            participant = s.participant,
            experiment = s.experiment_name,
            variables = series_variables_text(s, vars_by_exp[s.experiment_name]),
            repetitions = length(s.entries),
            trials = trials_text(valid, planned),
            last_run = started_text(latest_time),
            state = last(session_rows).state,
            continuable = any(r -> r.continuable, session_rows),
            sessions = session_rows,
        )
        push!(rows_with_time, (latest_time, row))
    end

    sort!(rows_with_time;
          by = item -> (first(item) === nothing, -something(first(item), 0.0), last(item).key))
    return DashboardSeriesRow[last(item) for item in rows_with_time]
end

"""
    dashboard_dataset_rows(entries, filters = DashboardFilters()) -> Vector{DashboardEntryRow}

The combined datasets matching `filters`, newest first.
"""
function dashboard_dataset_rows(entries::AbstractVector{LibraryEntry},
                                filters::DashboardFilters = DashboardFilters())
    kept = filtered_entries(entries, filters)
    datasets = LibraryEntry[e for e in kept if e.kind === :set]
    sort!(datasets; by = entry_sort_key)
    return dashboard_entry_row.(reverse(datasets))
end

# ── Series ticks and selection ───────────────────────────────────────────────

"""
    series_tick_state(row, ticked) -> Symbol

Returns `:all` when every session in `row` is ticked, `:none` when none is, and `:some`
when part of the series is ticked.
"""
function series_tick_state(row::DashboardSeriesRow, ticked::AbstractVector{<:AbstractString})
    isempty(row.sessions) && return :none
    n = count(s -> s.path in ticked, row.sessions)
    n == 0 && return :none
    n == length(row.sessions) && return :all
    return :some
end

series_tick_state(row::DashboardSeriesRow, controller::DashboardController) =
    series_tick_state(row, controller.ticked)

"""
    tick_series!(controller, row, on::Bool) -> controller

Ticks or unticks every session belonging to `row`.
"""
function tick_series!(controller::DashboardController, row::DashboardSeriesRow, on::Bool)
    for session_row in row.sessions
        tick_session!(controller, session_row.path, on)
    end
    return controller
end

"""
    choose_series!(controller, row) -> Bool

Opens the latest session of `row` with [`open_previous_session!`](@ref): a finished one
is shown so `Start New Session` runs its next repetition; an unfinished one continues.
"""
function choose_series!(controller::DashboardController, row::DashboardSeriesRow)
    isempty(row.sessions) && return false
    return open_previous_session!(controller, last(row.sessions).path)
end

# ── Parameters over several ticked sessions ──────────────────────────────────

function value_counts(values)
    counts = Pair{Any, Int}[]
    for val in values
        idx = findfirst(p -> isequal(first(p), val), counts)
        if idx === nothing
            push!(counts, val => 1)
        else
            counts[idx] = first(counts[idx]) => last(counts[idx]) + 1
        end
    end
    return counts
end

format_ticked_value(::Absent) = "—"
format_ticked_value(val) = format_setting(val)

function ticked_summary_row(label::String, values;
                            key::Union{Nothing, String} = nothing,
                            editable_diff_empty::Bool = false)
    counts = value_counts(values)
    if length(counts) == 1
        val_str = format_ticked_value(first(counts[1]))
        return ParameterRow(; key, label, value = val_str, edit = val_str, differs = false)
    end
    val_str = ui_label(:ticked_differs; count = length(counts))
    tip = join((ui_label(:ticked_value_count; value = format_ticked_value(v), count = n)
                for (v, n) in counts), "\n")
    return ParameterRow(; key, label, value = val_str,
                        edit = editable_diff_empty ? "" : val_str,
                        differs = true, tooltip = tip)
end

function entry_parameter_display_value(entry::LibraryEntry, param::Symbol)
    haskey(entry.parameters, param) || return ABSENT
    param in entry.indep_var_names && return ui_label(:set_by_design)
    stim_idx = findfirst(pair -> first(pair) === :stimulus, entry.facts)
    if stim_idx !== nothing
        stim_dict = last(entry.facts[stim_idx])
        if stim_dict isa AbstractDict && !haskey(stim_dict, string(param))
            return ui_label(:set_by_method)
        end
    end
    return entry.parameters[param]
end

"""
    ticked_parameter_rows(entries) -> Vector{ParameterRow}

Builds the Parameters view's rows for several ticked sessions from their
[`LibraryEntry`](@ref) records alone (without loading any session file). A value shared by
all sessions is shown as itself; one in which they differ sets `differs = true` with the
breakdown in `tooltip`. Experiment name, tags, and comment rows carry editable keys for
[`edit_ticked_labels!`](@ref).
"""
function ticked_parameter_rows(entries::AbstractVector{LibraryEntry})
    isempty(entries) && return ParameterRow[]
    rows = ParameterRow[]

    push!(rows, ParameterRow(label = ui_label(:ticked_sessions),
                             value = string(length(entries))))

    participant_counts = value_counts(String[join(e.participants, ", ") for e in entries])
    all_participants = unique(String[p for e in entries for p in e.participants])
    p_tip = length(participant_counts) > 1 ?
            join((ui_label(:ticked_value_count; value = v, count = n)
                  for (v, n) in participant_counts), "\n") : nothing
    push!(rows, ParameterRow(label = ui_label(:column_participants),
                             value = format_setting(all_participants),
                             tooltip = p_tip))

    push!(rows, ticked_summary_row(ui_label(:setup_experiment),
                                   [e.experiment_name for e in entries];
                                   key = "experiment_name", editable_diff_empty = true))
    push!(rows, ticked_summary_row(ui_label(:setup_method), [e.method for e in entries]))
    push!(rows, ticked_summary_row(ui_label(:setup_stimulus), [e.stimulus for e in entries]))

    var_names = Symbol[]
    for e in entries, v in e.indep_var_names
        v in var_names || push!(var_names, v)
    end
    for v in var_names
        vals = Any[(v in e.indep_var_names && haskey(e.levels, v)) ? e.levels[v] : ABSENT
                   for e in entries]
        push!(rows, ticked_summary_row(ui_label(:ticked_variable_levels; variable = string(v)),
                                       vals))
    end

    param_names = sort!(unique(Symbol[k for e in entries for k in keys(e.parameters)]);
                        by = string)
    for param in param_names
        vals = Any[entry_parameter_display_value(e, param) for e in entries]
        push!(rows, ticked_summary_row(string(param), vals))
    end

    common = shared_tags([e.tags for e in entries])
    common_text = join(common, ", ")
    tag_sets = [sort!(unique(String.(e.tags))) for e in entries]
    tag_counts = value_counts(tag_sets)
    tags_differ = length(tag_counts) > 1
    tag_tip = tags_differ ?
              join((ui_label(:ticked_value_count;
                             value = isempty(ts) ? "—" : join(ts, ", "),
                             count = n)
                    for (ts, n) in tag_counts), "\n") : nothing
    push!(rows, ParameterRow(key = "tags", label = ui_label(:setup_tags),
                             value = common_text, edit = common_text,
                             differs = tags_differ, tooltip = tag_tip))

    push!(rows, ParameterRow(key = "comment", label = ui_label(:ticked_comment),
                             value = "", edit = "",
                             tooltip = ui_label(:tip_ticked_comment)))

    return rows
end
