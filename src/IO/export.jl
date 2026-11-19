"""
    export_session(session, path; format=:csv, content=:trials, valid_only=false,
                   collapse=())

Export one session to a UTF-8 CSV or TSV file. The file starts with `#`-prefixed
session metadata, followed by a column header and either the full trial history
or per-condition summary rows. Trial exports retain invalidated rows unless
`valid_only=true` is requested.

`collapse` pools a summary's trials over the variables it names, such as a
counterbalancing `:target_interval` ([`get_aggregated_data`](@ref)): the rows then
hold the variables kept, and the metadata names the pooled ones. Trial rows record
each trial's full condition, so a trial export refuses `collapse`.

Trial rows hold the values as recorded; a variable or a response the session
converts ([`set_unit_conversion!`](@ref)) gets a further column, headed by the
conversion's label, beside the recorded one. A session whose response is an adjusted
value also has a `start_value` column, where each adjustment began
([`Trial`](@ref)), converted beside it as the response is. Summary rows are in the
converted units, and the metadata writes each conversion out.

`format` must be `:csv` or `:tsv`; `content` must be `:trials` or `:summary`.
"""
function export_session(session::SessionContext, path::AbstractString;
                        format=:csv, content=:trials,
                        valid_only::Bool=false, collapse=())
    separator = export_separator(format)
    columns, rows = export_columns_and_rows(session, content, valid_only, collapse)
    return write_export_file(path, export_metadata(session, collapse), columns, rows,
                             separator)
end

"""
    export_session(checkpoint_path, out_path; kwargs...)

Load a JSON checkpoint and export it. This convenience form has the same
keywords as the session-based method.
"""
function export_session(checkpoint_path::AbstractString, out_path::AbstractString;
                        kwargs...)
    return export_session(load_session(checkpoint_path), out_path; kwargs...)
end

"""
    export_session(set::AnalysisSet, path::AbstractString;
                   format = :csv, content = :trials, valid_only::Bool = false,
                   split::Bool = false, collapse = ())

Export an [`AnalysisSet`](@ref) to UTF-8 CSV or TSV files. When `split=false`,
writes one file starting with combined dataset metadata followed by either trial
history (with extra `session_id` and `participant_id` leading columns) or pooled
per-condition summary rows from [`get_aggregated_data`](@ref), returning `path`.
`collapse` pools a summary as for a single session.

When `split=true`, exports each member session into its own file named
`<stem>_<id[1:8]><ext>` and returns the `Vector{String}` of written paths.
"""
function export_session(set::AnalysisSet, path::AbstractString;
                        format = :csv, content = :trials,
                        valid_only::Bool = false, split::Bool = false, collapse = ())
    separator = export_separator(format)
    content in (:trials, :summary) ||
        throw(ArgumentError("Unknown export content: $content. Use :trials or :summary."))
    isempty(set.sessions) &&
        throw(ArgumentError("An empty analysis set has nothing to export."))

    if split
        stem, ext = splitext(path)
        return String[
            export_session(member, stem * "_" * string(member.id)[1:8] * ext;
                           format = format, content = content, valid_only = valid_only,
                           collapse = collapse)
            for member in set.sessions
        ]
    end

    columns, rows = export_columns_and_rows(set, content, valid_only, collapse)
    return write_export_file(path, export_metadata(set, collapse), columns, rows, separator)
end

function export_separator(format)
    format === :csv && return ','
    format === :tsv && return '\t'
    throw(ArgumentError("Unknown export format: $format. Use :csv or :tsv."))
end

# The design's columns of a trial row: each independent variable and the response
# as recorded, each followed by its converted value when the session declares a
# conversion for it. The recorded column stays, because the record is in the units
# the stimulus was presented in.
function design_columns(session::SessionContext)
    columns = Pair{String, Function}[]
    for (index, name) in enumerate(session.ex_par.indep_var_names)
        push!(columns, string(name) => trial -> trial.indep_var_vals[index])
        conversion = get(session.unit_conversions, name, nothing)
        conversion === nothing ||
            push!(columns, conversion.label => trial -> conversion(trial.indep_var_vals[index]))
    end
    push!(columns, "response" => trial -> trial.response)
    variable = response_variable(session.method_instance)
    # Named apart from the loop's `conversion`, which the closures above capture
    to_unit = variable === nothing ? nothing : get(session.unit_conversions, variable, nothing)
    # A response that is not a value — a timeout, a presentation never answered —
    # is shown as itself in the converted column too
    to_unit === nothing || push!(columns, to_unit.label => trial ->
        trial.response isa Real && !isnan(trial.response) ? to_unit(trial.response) :
                                                            trial.response)
    # Where each adjustment began, in the same units as the value it ended on
    if variable !== nothing
        push!(columns, "start_value" => trial -> trial.start_value)
        to_unit === nothing || push!(columns, "start " * to_unit.label => trial ->
            trial.start_value === nothing ? nothing : to_unit(trial.start_value))
    end
    return columns
end

# Trial rows record each trial's full condition, so only a summary pools
function refuse_collapsed_trials(collapse)
    isempty(pooled_variables(collapse)) || throw(ArgumentError(
        "A trial export records each trial's full condition; collapse pools a summary " *
        "only (content = :summary)."))
    return nothing
end

function export_columns_and_rows(session::SessionContext, content,
                                 valid_only::Bool, collapse = ())
    if content === :trials
        refuse_collapsed_trials(collapse)
        design = design_columns(session)
        columns = vcat(
            ["trial_index"], first.(design),
            ["correct", "reaction_time_s", "is_valid", "timestamp_onset",
             "timestamp_response", "onset_source", "origin"],
        )
        trials = valid_only ? (t for t in session.history if t.is_valid) : session.history
        rows = [Any[
            trial.trial_index,
            (cell(trial) for cell in last.(design))...,
            trial.correct,
            trial.timestamp_response - trial.timestamp_onset,
            trial.is_valid,
            trial.timestamp_onset,
            trial.timestamp_response,
            string(trial.onset_source),
            string(trial.origin),
        ] for trial in trials]
        return columns, rows
    elseif content === :summary
        return summary_export_table(session, collapse)
    end
    throw(ArgumentError("Unknown export content: $content. Use :trials or :summary."))
end

function export_columns_and_rows(set::AnalysisSet, content, valid_only::Bool,
                                 collapse = ())
    content === :summary && return summary_export_table(set, collapse)
    content === :trials || throw(ArgumentError(
        "Unknown export content: $content. Use :trials or :summary."))
    refuse_collapsed_trials(collapse)
    columns = String[]
    rows = Vector{Any}[]
    # Members of a set name the same variables, so each member's trial columns are the set's
    for member in set.sessions
        columns, member_rows = export_columns_and_rows(member, :trials, valid_only)
        append!(rows, (vcat(Any[string(member.id), member.participant_id], row)
                       for row in member_rows))
    end
    return vcat(["session_id", "participant_id"], columns), rows
end

# The summary is an analysis: its levels and means are in the declared units
function summary_export_table(data::SessionOrSet, collapse = ())
    session = design_session(data)
    columns = vcat([variable_label(session, name) for name in kept_variables(data, collapse)],
                   ["n", "mean_response", "sd", "sem", "ci_lo", "ci_hi",
                    "proportion_correct", "correct_ci_lo", "correct_ci_hi"])
    # A single trial or an unscored condition has no interval, which the table leaves empty
    interval(x) = isnan(x) ? nothing : x
    rows = [Any[point.vals..., point.n, point.mean_response, point.sd, point.sem,
                interval(point.ci_lo), interval(point.ci_hi), point.proportion_correct,
                interval(point.correct_ci_lo), interval(point.correct_ci_hi)]
            for point in get_aggregated_data(data; collapse)]
    return columns, rows
end

function export_metadata(session::SessionContext, collapse = ())
    return Pair{String, Any}[
        "participant_id" => session.participant_id,
        "experiment_name" => session.ex_par.experiment_name,
        "method" => type_name(session.method_instance),
        # The Core records this type name when a session is run.
        "engine" => session.engine_name,
        "independent_variables" => join(string.(session.ex_par.indep_var_names), ","),
        "repeats" => session.ex_par.repeats,
        "tags" => join(session.tags, ","),
        "session_id" => string(session.id),
        "program_version" => session.program_version,
        "start_time" => export_time(session.start_time),
        "min_response_s" => session.min_response_s,
        rig_metadata([session])...,
        "export_time" => export_time(time()),
        unit_metadata([session])...,
        collapse_metadata(collapse)...,
        comment_metadata(session)...,
    ]
end

# One line per comment, the time it was written and the trial it is about before it;
# a metadata line is one line, so a comment's line breaks become spaces
comment_metadata(session::SessionContext; prefix::AbstractString = "") =
    Pair{String, Any}["comment" => prefix * export_time(comment.time) *
                                   (comment.trial === nothing ? "" : " trial $(comment.trial)") *
                                   ": " * replace(comment.text, r"\s*\R\s*" => " ")
                      for comment in session.comments]

function export_metadata(set::AnalysisSet, collapse = ())
    design = design_session(set)
    members = set.sessions
    return Pair{String, Any}[
        "sessions" => length(members),
        "session_ids" => join((string(member.id) for member in members), ","),
        "participant_ids" => join(unique(member.participant_id for member in members), ","),
        "experiment_names" =>
            join(unique(member.ex_par.experiment_name for member in members), ","),
        "method" => type_name(design.method_instance),
        "independent_variables" => join(string.(design.ex_par.indep_var_names), ","),
        "export_time" => export_time(time()),
        rig_metadata(members)...,
        unit_metadata(members)...,
        collapse_metadata(collapse)...,
        (pair for member in members
              for pair in comment_metadata(member; prefix = string(member.id)[1:8] * " "))...,
    ]
end

collapse_metadata(collapse) = isempty(pooled_variables(collapse)) ? Pair{String, Any}[] :
    Pair{String, Any}["collapsed_over" => join(string.(pooled_variables(collapse)), ",")]

# The rig's name and constants, a line each; the members of a set measured on different
# rigs give their values one after another
function rig_metadata(sessions)
    keys_found = unique(key for session in sessions for key in keys(session.rig))
    ordered = sort(keys_found; by = key -> (key != "name", key))
    return Pair{String, Any}[
        "rig.$key" => join(unique(string(session.rig[key])
                                  for session in sessions if haskey(session.rig, key)), "; ")
        for key in ordered]
end

# One line per converted variable, and the name the responses are shown under. The
# members of a set agree on the labels but may convert differently, so a set's line
# lists every formula its members use.
function unit_metadata(sessions)
    variables = sort(unique(variable for session in sessions
                            for variable in keys(session.unit_conversions)))
    metadata = Pair{String, Any}[
        "unit_conversion.$variable" => join(unique(
            conversion_formula(variable, session.unit_conversions[variable])
            for session in sessions if haskey(session.unit_conversions, variable)), "; ")
        for variable in variables]
    label = response_label(last(sessions))
    label === nothing || push!(metadata, "response_label" => label)
    return metadata
end

function write_export_file(path::AbstractString, metadata, columns, rows, separator::Char)
    open(path, "w") do io
        for (key, value) in metadata
            write(io, "# ", key, ": ", export_field(value, separator), '\n')
        end
        write_export_row(io, columns, separator)
        for row in rows
            write_export_row(io, row, separator)
        end
    end
    return path
end

export_time(timestamp::Nothing) = "-"
export_time(timestamp::Real) = Dates.format(
    unix2datetime(timestamp), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ",
)

# An unscored trial or condition leaves the cell empty rather than spelling out
# a Julia value: a reader must see missing data, not the word "nothing".
export_field(::Nothing, ::Char) = ""

# Minimal RFC-4180 field writer. It deliberately does not use DelimitedFiles:
# that stdlib writer does not quote free-text participant identifiers or tags.
function export_field(value, separator::Char)
    text = string(value)
    if occursin(separator, text) || occursin('"', text) ||
       occursin('\n', text) || occursin('\r', text)
        return "\"" * replace(text, '"' => "\"\"") * "\""
    end
    return text
end

function write_export_row(io::IO, values, separator::Char)
    println(io, join((export_field(value, separator) for value in values), separator))
    return nothing
end
