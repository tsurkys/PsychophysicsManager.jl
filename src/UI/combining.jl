# Combining checks for series and datasets, and saving ticked sessions as a combined
# dataset from Browse. The admission itself is the analysis set's (`admit_session!`);
# its refusals reach the operator in the panel instead of the console.

# The checks series and datasets start from: the settings' own, all of them when the
# settings name one that is not a check — combining is strict unless relaxed
function settings_combining_checks()
    try
        return load_combining_checks()
    catch err
        err isa ArgumentError || rethrow()
        @warn "Every combining check is on: $(err.msg)"
        return collect(COMBINING_CHECKS)
    end
end

"""
    set_combining_check!(controller, check::Symbol, on::Bool) -> controller

Switches one optional check ([`COMBINING_CHECKS`](@ref)) on or off for series grouping
and `Save as Dataset…`, without touching `settings.toml`.
"""
function set_combining_check!(controller::DashboardController, check::Symbol, on::Bool)
    check in COMBINING_CHECKS || throw(ArgumentError(
        "$(repr(check)) is not a combining check; the checks are " *
        "$(join(repr.(COMBINING_CHECKS), ", "))."))
    checks = controller.checks
    controller.checks = [c for c in COMBINING_CHECKS
                         if c == check ? on : c in checks]
    return controller
end

function admission_reason_text(outcome::Symbol, differing)
    outcome === :duplicate && return ui_label(:combine_duplicate)
    outcome === :discarded && return ui_label(:combine_discarded)
    return ui_label(:combine_differs;
                    facts = join((isempty(fields) ?
                                  ui_label(Symbol("fact_", name)) :
                                  ui_label(:fact_stimulus_fields;
                                           fields = join(fields, ", "))
                                  for (name, fields) in differing), ", "))
end

"""
    save_ticked_dataset!(controller, name) -> Bool

Builds an [`AnalysisSet`](@ref) of the ticked sessions under `controller.checks` and
saves it via [`save_analysis_set`](@ref) into the data directory under `name`, never
overwriting an existing file. Refuses when nothing is ticked or `name` is empty or
already exists. Any ticked session left out is named in the panel message with the
reason. Returns whether a dataset was saved.
"""
function save_ticked_dataset!(controller::DashboardController, name::AbstractString)
    if isempty(controller.ticked)
        set_message!(controller, ui_label(:msg_dataset_none_ticked))
        return false
    end
    trimmed = strip(name)
    if isempty(trimmed) || any(c -> c in "/\\:", trimmed)
        set_message!(controller, ui_label(:msg_dataset_name))
        return false
    end
    path = joinpath(resolve_data_dir(),
                    endswith(lowercase(trimmed), ".json") ? trimmed : trimmed * ".json")
    if isfile(path)
        set_message!(controller, ui_label(:msg_dataset_exists; name = basename(path)))
        return false
    end

    loaded = Pair{String, SessionContext}[]
    left_out = String[]
    for file in controller.ticked
        try
            push!(loaded, file => load_session(file))
        catch err
            push!(left_out,
                  "$(splitext(basename(file))[1]) ($(ui_label(:combine_unreadable; error = sprint(showerror, err))))")
        end
    end
    sort!(loaded; by = entry -> something(last(entry).start_time, Inf))

    set = AnalysisSet(; checks = controller.checks)
    for (file, session) in loaded
        outcome, differing = admit_session!(set, session)
        if outcome !== :added
            push!(left_out,
                  "$(splitext(basename(file))[1]) ($(admission_reason_text(outcome, differing)))")
        end
    end

    if isempty(set.sessions)
        set_message!(controller,
                     ui_label(:msg_dataset_nothing_added) *
                     (isempty(left_out) ? "" :
                      " " * ui_label(:msg_dataset_left_out; files = join(left_out, "; "))))
        return false
    end

    saved = try
        save_analysis_set(set, path)
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_dataset_failed; error = err.msg))
        return false
    end

    controller.lists_stale = true
    set_message!(controller,
                 ui_label(:msg_dataset_saved; path = saved, sessions = length(set.sessions)) *
                 (isempty(left_out) ? "" :
                  " " * ui_label(:msg_dataset_left_out; files = join(left_out, "; "))))
    return true
end
