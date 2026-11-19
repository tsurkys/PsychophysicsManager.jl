# The session library: what a data directory holds,
# read from the files themselves. A catalogue is built without restoring a single
# method or engine — browsing a laboratory's year of data must not activate a backend
# or replay an adaptive method's state.

"""
    LibraryEntry

One file of a data directory as [`browse_sessions`](@ref) reports it: a saved session,
or a combined dataset ([`AnalysisSet`](@ref)), which is one entry holding all of its
members rather than one entry each.

`kind` is `:session` or `:set`; `ids` names the session, or the set's members in the
order they were added; `participants`, `tags` and `comments` are those of the file
(`participants` and `tags` without repetitions). `experiment_name`, `method`, `stimulus`,
`indep_var_names`, `parameters`, `levels` and `facts` are the design — of a set, its
last member's, which is the one a new experiment starts from. `parameters` holds all stored
stimulus parameters passed through `fact_value`, `levels` holds each independent
variable's levels, and `facts` holds `stored_combining_facts` with every check on.
`state` is `nothing` for a set, which has no run of its own, and a set's `start_time`
is that of the member measured first. `trials` counts what was recorded, `valid_trials`
what an analysis reads (`is_valid`), and `planned_trials` the valid trials planned when
known (`nothing` otherwise).

The file is described as it stands on disk: `method` and `stimulus` are the type names
it names, so a session measured with a method this installation does not have is still
listed, and `load_session` is what refuses it.
"""
struct LibraryEntry
    path::String
    kind::Symbol
    ids::Vector{String}
    participants::Vector{String}
    tags::Vector{String}
    experiment_name::String
    method::String
    stimulus::String
    indep_var_names::Vector{Symbol}
    state::Union{Nothing, SessionState}
    start_time::Union{Nothing, Float64}
    trials::Int
    valid_trials::Int
    planned_trials::Union{Nothing, Int}
    comments::Vector{String}
    parameters::Dict{Symbol, Any}
    levels::Dict{Symbol, Vector{Any}}
    facts::Vector{Pair{Symbol, Any}}
end

Base.:(==)(a::LibraryEntry, b::LibraryEntry) =
    all(field -> getfield(a, field) == getfield(b, field), fieldnames(LibraryEntry))

Base.isequal(a::LibraryEntry, b::LibraryEntry) =
    all(field -> isequal(getfield(a, field), getfield(b, field)), fieldnames(LibraryEntry))

function Base.hash(entry::LibraryEntry, h::UInt)
    h = hash(:LibraryEntry, h)
    for field in fieldnames(LibraryEntry)
        h = hash(getfield(entry, field), h)
    end
    return h
end

function Base.show(io::IO, entry::LibraryEntry)
    print(io, basename(entry.path), "  ", join(entry.participants, ", "), "  ",
          entry.method, "  ",
          entry.kind === :set ? "dataset of $(length(entry.ids)) sessions" :
                                string(entry.state),
          "  ", entry.valid_trials, "/", entry.trials, " trials")
end

function Base.show(io::IO, ::MIME"text/plain", entry::LibraryEntry)
    started = entry.start_time === nothing ? "never started" :
              Dates.format(unix2datetime(entry.start_time), "yyyy-mm-dd HH:MM")
    print(io, entry.path, "\n  ", entry.experiment_name, " — ", entry.stimulus, " — ",
          join(entry.indep_var_names, ", "), "\n  ")
    show(io, entry)
    print(io, "  ", started)
    isempty(entry.tags) || print(io, "\n  tags: ", join(entry.tags, ", "))
end

# ── Fact normalization and stored combining facts ────────────────────────────

const ALWAYS_COMBINING_FACTS = (:stimulus_type, :method, :independent_variables,
                                :response_coding, :fit_gamma, :observer_kind, :units)

"""
    fact_value(x)

Converts a combining-fact value into a plain JSON-comparable form so values read from a
stored session file and values from a loaded [`SessionContext`](@ref) compare equal under
`isequal`: symbols become strings, tuples and vectors become `Vector{Any}`, and
dictionaries become `Dict{String, Any}`. Numbers stay as they are, because `isequal(1, 1.0)`
and their hashes agree.
"""
fact_value(x::Symbol) = String(x)
fact_value(x::Union{Tuple, AbstractVector}) = Any[fact_value(item) for item in x]
fact_value(x::AbstractDict) =
    Dict{String, Any}(string(key) => fact_value(val) for (key, val) in x)
fact_value(x) = x

"""
    session_facts(session::SessionContext, checks) -> Vector{Pair{Symbol, Any}}

The combining facts of a loaded `session` under `checks`, each value normalized with
[`fact_value`](@ref).
"""
session_facts(session::SessionContext, checks) =
    Pair{Symbol, Any}[name => fact_value(value)
                      for (name, value) in combining_facts(session, checks)]

function stored_method_kind(stored::AbstractDict)
    kind = String(get(stored, "_type", ""))
    kind == "Interleaved" || return kind
    fields = get(stored, "fields", Dict{String, Any}())
    tracks = something(get(fields, "tracks", Any[]), Any[])
    return (kind, map(stored_method_kind, tracks)...)
end

"""
    stored_combining_facts(stored::AbstractDict, checks) -> Vector{Pair{Symbol, Any}}

Reads the same facts as [`combining_facts`](@ref) directly from a parsed session JSON
dictionary under `checks`, without loading the session, with each value passed through
[`fact_value`](@ref).
"""
function stored_combining_facts(stored::AbstractDict, checks)
    ex_par = get(stored, "ex_par", Dict{String, Any}())
    stim_par = get(stored, "stim_par", Dict{String, Any}())
    method_instance = get(stored, "method_instance", Dict{String, Any}())
    task = get(stored, "task", nothing)
    raw_tags = something(get(stored, "tags", String[]), String[])
    tags = String[String(t) for t in raw_tags]
    observer_metadata = something(get(stored, "observer_metadata", Dict{String, Any}()),
                                  Dict{String, Any}())
    unit_conversions = something(get(stored, "unit_conversions", Dict{String, Any}()),
                                 Dict{String, Any}())
    raw_indep_names = something(get(ex_par, "indep_var_names", String[]), String[])

    raw_facts = Pair{Symbol, Any}[
        :stimulus_type => (String(get(stim_par, "_type", "")),
                           stored_stimulus_name(stim_par)),
        :method => stored_method_kind(method_instance),
        :independent_variables => Symbol[Symbol(name) for name in raw_indep_names],
        :response_coding => task === nothing ? nothing :
                            (Tuple(String.(task["options"])), String(task["positive_option"])),
        :fit_gamma => get(stored, "fit_gamma", DEFAULT_FIT_GAMMA),
        :observer_kind => (!isempty(observer_metadata) || MODEL_OBSERVER_TAG in tags) ?
                          :program : :person,
        :units => Dict(Symbol(variable) => String(conversion["label"])
                       for (variable, conversion) in unit_conversions),
    ]

    if :instructions in checks
        push!(raw_facts,
              :instructions => task === nothing ? nothing : String(task["instructions"]))
    end
    if :observer in checks
        push!(raw_facts,
              :observer => filter(entry -> !(string(first(entry)) in ("requests", "failed_requests")),
                                  observer_metadata))
    end
    if :feedback in checks
        push!(raw_facts, :feedback => get(stored, "feedback", false))
    end
    if :timeout in checks
        push!(raw_facts, :timeout => get(stored, "timeout_s", nothing))
    end
    if :stimulus in checks
        indep_names = Set(String[String(n) for n in raw_indep_names])
        raw_adjusted = get(stored, "adjusted_fields", String[])
        adjusted = raw_adjusted === nothing ? Set{String}() :
                   Set(String[String(n) for n in raw_adjusted])
        excluded = union(indep_names, adjusted)
        stim_fields = get(stim_par, "fields", Dict{String, Any}())
        push!(raw_facts,
              :stimulus => Dict(Symbol(name) => value
                                for (name, value) in stim_fields
                                if !(string(name) in excluded)))
    end

    return Pair{Symbol, Any}[name => fact_value(value) for (name, value) in raw_facts]
end

# ── Library index cache ──────────────────────────────────────────────────────

const LIBRARY_INDEX_FILE = ".pem-library-index"
const LIBRARY_INDEX_VERSION = 2

relative_index_path(path::AbstractString, root::AbstractString) =
    join(splitpath(relpath(abspath(path), abspath(root))), "/")

function entry_to_index(entry::LibraryEntry, root::Union{Nothing, AbstractString} = nothing)
    stored_path = root === nothing ? entry.path : relative_index_path(entry.path, root)
    return Dict{String, Any}(
        "path" => stored_path,
        "kind" => String(entry.kind),
        "ids" => entry.ids,
        "participants" => entry.participants,
        "tags" => entry.tags,
        "experiment_name" => entry.experiment_name,
        "method" => entry.method,
        "stimulus" => entry.stimulus,
        "indep_var_names" => string.(entry.indep_var_names),
        "state" => entry.state === nothing ? nothing : string(entry.state),
        "start_time" => entry.start_time,
        "trials" => entry.trials,
        "valid_trials" => entry.valid_trials,
        "planned_trials" => entry.planned_trials,
        "comments" => entry.comments,
        "parameters" => Dict{String, Any}(string(k) => v for (k, v) in entry.parameters),
        "levels" => Dict{String, Any}(string(k) => v for (k, v) in entry.levels),
        "facts" => Any[Any[string(name), value] for (name, value) in entry.facts],
    )
end

function entry_from_index(stored::AbstractDict, root::AbstractString)
    raw_path = String(stored["path"])
    full_path = isabspath(raw_path) ? abspath(raw_path) :
                abspath(joinpath(abspath(root), split(raw_path, '/')...))
    state_raw = stored["state"]
    start_raw = stored["start_time"]
    planned_raw = stored["planned_trials"]
    return LibraryEntry(
        full_path,
        Symbol(stored["kind"]),
        String[String(id) for id in stored["ids"]],
        String[String(p) for p in stored["participants"]],
        String[String(t) for t in stored["tags"]],
        String(stored["experiment_name"]),
        String(stored["method"]),
        String(stored["stimulus"]),
        Symbol[Symbol(name) for name in stored["indep_var_names"]],
        state_raw === nothing ? nothing : session_state(String(state_raw)),
        start_raw === nothing ? nothing : Float64(start_raw),
        Int(stored["trials"]),
        Int(stored["valid_trials"]),
        planned_raw === nothing ? nothing : Int(planned_raw),
        String[String(c) for c in stored["comments"]],
        Dict{Symbol, Any}(Symbol(k) => fact_value(v) for (k, v) in stored["parameters"]),
        Dict{Symbol, Vector{Any}}(Symbol(k) => Any[fact_value(x) for x in v]
                                  for (k, v) in stored["levels"]),
        Pair{Symbol, Any}[Symbol(pair[1]) => fact_value(pair[2]) for pair in stored["facts"]],
    )
end

function load_library_index(index_path::AbstractString)
    isfile(index_path) || return (Dict{String, Any}(), false)
    doc = try
        JSON3.read(read(index_path, String), Dict{String, Any})
    catch
        return (Dict{String, Any}(), false)
    end
    doc isa AbstractDict || return (Dict{String, Any}(), false)
    get(doc, "version", nothing) === LIBRARY_INDEX_VERSION ||
        return (Dict{String, Any}(), false)
    files = get(doc, "files", nothing)
    files isa AbstractDict || return (Dict{String, Any}(), false)
    return (Dict{String, Any}(String(k) => v for (k, v) in files), true)
end

function save_library_index(index_path::AbstractString, files::Dict{String, Any})
    payload = Dict{String, Any}(
        "version" => LIBRARY_INDEX_VERSION,
        "files" => files,
    )
    try
        atomic_write(io -> JSON3.write(io, payload), String(index_path))
    catch err
        @debug "Could not update the session library index $index_path" exception = err
    end
    return nothing
end

function resolve_library_entry(path::AbstractString, rel::String,
                               old_files::Dict{String, Any}, root_dir::String)
    st = stat(path)
    file_size = Int64(st.size)
    file_mtime = Float64(st.mtime)
    cached = get(old_files, rel, nothing)
    if cached isa AbstractDict
        cached_size = get(cached, "size", nothing)
        cached_mtime = get(cached, "mtime", nothing)
        if cached_size isa Integer && !(cached_size isa Bool) && cached_size == file_size &&
           cached_mtime isa Real && !(cached_mtime isa Bool) &&
           Float64(cached_mtime) == file_mtime && haskey(cached, "entry")
            raw_entry = cached["entry"]
            if raw_entry === nothing
                return (:not_ours, nothing, cached, false)
            elseif raw_entry isa AbstractDict
                restored = try
                    entry_from_index(raw_entry, root_dir)
                catch
                    nothing
                end
                restored === nothing || return (:ok, restored, cached, false)
            end
        end
    end

    status, entry = try
        (:ok, library_entry(path))
    catch
        (:error, nothing)
    end
    status === :error && return (:error, nothing, nothing, haskey(old_files, rel))
    if entry === nothing
        record = Dict{String, Any}("size" => file_size, "mtime" => file_mtime,
                                    "entry" => nothing)
        return (:not_ours, nothing, record, true)
    end
    record = Dict{String, Any}("size" => file_size, "mtime" => file_mtime,
                                "entry" => entry_to_index(entry, root_dir))
    return (:ok, entry, record, true)
end

# ── Browsing and filtering ───────────────────────────────────────────────────

"""
    browse_sessions(directory = resolve_data_dir(); participant = nothing,
                    experiment = nothing, tags = nothing, method = nothing,
                    stimulus = nothing, state = nothing, from = nothing, to = nothing,
                    parameter = nothing, text = nothing) -> Vector{LibraryEntry}

What `directory` holds, oldest first: every saved session and every combined dataset in
it and its subdirectories (skipping `discarded` folders), as [`LibraryEntry`](@ref) values,
without any of them being loaded.

The keywords filter the catalogue (all supplied filters must hold): `participant` one id or
a collection of ids (matches when any was measured), `experiment` an exact experiment name,
`tags` one tag or several that must all be present, `method` the method it was measured
with (a type or its name), `stimulus` a stimulus name (`entry.stimulus`), `state` the
lifecycle state it stopped in (`READY`, `PAUSED` and `RUNNING` can continue; datasets have
no state), `from` and `to` a `Date` or `DateTime` bounding `start_time` in UTC (a `Date`
for `to` includes the whole day, and a never-started entry matches neither), `parameter` a
`name => value` pair or collection of them (matching independent-variable levels or
non-independent stimulus parameters under `isequal`), and `text` a case-insensitive
substring of the file's base name, experiment name, participants, tags or comments.

```julia
for entry in browse_sessions(; participant = "P01", state = PAUSED)
    println(entry, "  ", get_participant(only(entry.participants)))
end
```

What is known about the people themselves is joined by their id, through
[`get_participant`](@ref): the files name a participant and hold nothing more.

`method` is compared with the type the file names, so an interleaved run matches
`Interleaved` and not the methods of its tracks. A `.json` file that is neither a
session nor a dataset this version can read — another program's, or a checkpoint
truncated by a crash — is left out, and one warning names every file that was.
"""
function browse_sessions(directory::AbstractString = resolve_data_dir();
                         participant = nothing,
                         experiment::Union{Nothing, AbstractString} = nothing,
                         tags = nothing,
                         method::Union{Nothing, Type, AbstractString} = nothing,
                         stimulus::Union{Nothing, Type, AbstractString} = nothing,
                         state::Union{Nothing, SessionState} = nothing,
                         from::Union{Nothing, Date, DateTime} = nothing,
                         to::Union{Nothing, Date, DateTime} = nothing,
                         parameter = nothing,
                         text::Union{Nothing, AbstractString} = nothing)
    isdir(directory) || throw(ArgumentError(
        "There is no directory $directory to browse for sessions."))

    root_dir = abspath(directory)
    index_path = joinpath(root_dir, LIBRARY_INDEX_FILE)
    old_files, loaded_valid = load_library_index(index_path)
    new_files = Dict{String, Any}()
    changed = !loaded_valid

    entries = LibraryEntry[]
    unreadable = String[]
    for path in library_files(root_dir)
        rel = relative_index_path(path, root_dir)
        status, entry, record, record_changed =
            resolve_library_entry(path, rel, old_files, root_dir)
        changed |= record_changed
        if status === :ok
            push!(entries, entry)
            new_files[rel] = record
        elseif status === :not_ours
            push!(unreadable, path)
            new_files[rel] = record
        else
            push!(unreadable, path)
        end
    end
    if !changed && (length(new_files) != length(old_files) ||
                    any(k -> !haskey(new_files, k), keys(old_files)))
        changed = true
    end
    changed && save_library_index(index_path, new_files)

    isempty(unreadable) || @warn "Left out of the session library, being neither a " *
        "session nor a dataset this version can read: $(join(unreadable, ", "))."

    kept = filter_entries(entries; participant, experiment, tags, method, stimulus, state,
                          from, to, parameter, text)
    # A template has no start time and sorts last, and the path decides between files
    # of the same moment, so a listing is the same every time it is read
    return sort!(kept; by = entry_sort_key)
end

entry_sort_key(entry::LibraryEntry) =
    (entry.start_time === nothing, something(entry.start_time, 0.0), entry.path)

function filter_entries(entries::AbstractVector{LibraryEntry};
                        participant = nothing,
                        experiment::Union{Nothing, AbstractString} = nothing,
                        tags = nothing,
                        method::Union{Nothing, Type, AbstractString} = nothing,
                        stimulus::Union{Nothing, Type, AbstractString} = nothing,
                        state::Union{Nothing, SessionState} = nothing,
                        from::Union{Nothing, Date, DateTime} = nothing,
                        to::Union{Nothing, Date, DateTime} = nothing,
                        parameter = nothing,
                        text::Union{Nothing, AbstractString} = nothing)
    wanted_participants = participant === nothing ? nothing :
                          participant isa AbstractString ? String[String(participant)] :
                          String[String(p) for p in participant]
    wanted_experiment = experiment === nothing ? nothing : String(experiment)
    wanted_tags = tags === nothing ? String[] :
                  tags isa AbstractString ? String[String(tags)] :
                  String[String(t) for t in tags]
    wanted_method = method === nothing ? nothing :
                    method isa Type ? string(nameof(method)) : String(method)
    wanted_stimulus = stimulus === nothing ? nothing :
                      stimulus isa Type ? string(nameof(stimulus)) : String(stimulus)
    wanted_parameters = parameter === nothing ? Pair{Symbol, Any}[] :
                        parameter isa Pair ?
                        Pair{Symbol, Any}[Symbol(first(parameter)) => fact_value(last(parameter))] :
                        Pair{Symbol, Any}[Symbol(first(p)) => fact_value(last(p)) for p in parameter]
    needle = text === nothing ? nothing : lowercase(text)

    return LibraryEntry[entry for entry in entries
                        if (wanted_participants === nothing ||
                            any(p -> p in entry.participants, wanted_participants)) &&
                           (wanted_experiment === nothing ||
                            entry.experiment_name == wanted_experiment) &&
                           all(tag -> tag in entry.tags, wanted_tags) &&
                           (wanted_method === nothing || entry.method == wanted_method) &&
                           (wanted_stimulus === nothing || entry.stimulus == wanted_stimulus) &&
                           (state === nothing || entry.state === state) &&
                           matches_time_window(entry.start_time, from, to) &&
                           all(pair -> matches_parameter(entry, first(pair), last(pair)),
                               wanted_parameters) &&
                           (needle === nothing || matches_text(entry, needle))]
end

function matches_time_window(start_time::Union{Nothing, Float64},
                             from::Union{Nothing, Date, DateTime},
                             to::Union{Nothing, Date, DateTime})
    from === nothing && to === nothing && return true
    start_time === nothing && return false
    started = unix2datetime(start_time)
    from !== nothing && started < DateTime(from) && return false
    if to !== nothing
        to isa Date ? (started >= DateTime(to) + Day(1) && return false) :
                      (started > to && return false)
    end
    return true
end

function matches_parameter(entry::LibraryEntry, name::Symbol, wanted)
    if name in entry.indep_var_names
        haskey(entry.levels, name) || return false
        return any(level -> isequal(level, wanted), entry.levels[name])
    end
    return haskey(entry.parameters, name) && isequal(entry.parameters[name], wanted)
end

function matches_text(entry::LibraryEntry, needle::String)
    occursin(needle, lowercase(basename(entry.path))) && return true
    occursin(needle, lowercase(entry.experiment_name)) && return true
    any(p -> occursin(needle, lowercase(p)), entry.participants) && return true
    any(t -> occursin(needle, lowercase(t)), entry.tags) && return true
    any(c -> occursin(needle, lowercase(c)), entry.comments) && return true
    return false
end

function library_files(directory::AbstractString)
    root_dir = abspath(directory)
    paths = String[]
    for (root, _, files) in walkdir(root_dir), file in files
        # A walk from above passes by what was discarded; browsing the discarded
        # directory itself is how an operator sees what there is to restore
        DISCARDED_DIRECTORY in splitpath(relpath(root, root_dir)) && continue
        startswith(file, ".") && continue
        path = joinpath(root, file)
        # The extension, before the file is read: a data directory also holds the
        # participant registry, scenario state files, exports, and the .json.tmp of a
        # write a crash interrupted
        endswith(file, ".json") && isfile(path) && push!(paths, path)
    end
    return paths
end

# `nothing` for a file that is not one of ours; anything unreadable throws and is
# reported by the caller together with the rest
function library_entry(path::AbstractString)
    document = read_json_document(path)
    document isa AbstractDict || return nothing

    if is_analysis_set_document(document)
        members = [stored_session_facts(stored) for stored in document["sessions"]]
        isempty(members) && return nothing
        design = last(members)
        started = [member.start_time for member in members if member.start_time !== nothing]
        planned = all(member -> member.planned_trials !== nothing, members) ?
                  sum(member.planned_trials for member in members) : nothing
        return LibraryEntry(
            abspath(path), :set,
            String[member.id for member in members],
            unique(String[member.participant for member in members]),
            unique(String[tag for member in members for tag in member.tags]),
            design.experiment_name, design.method, design.stimulus,
            design.indep_var_names, nothing,
            isempty(started) ? nothing : minimum(started),
            sum(member.trials for member in members),
            sum(member.valid_trials for member in members),
            planned,
            String[comment for member in members for comment in member.comments],
            design.parameters, design.levels, design.facts)
    end

    (haskey(document, "id") && haskey(document, "ex_par")) || return nothing
    facts = stored_session_facts(document)
    return LibraryEntry(abspath(path), :session, [facts.id], [facts.participant],
                        facts.tags, facts.experiment_name, facts.method, facts.stimulus,
                        facts.indep_var_names, facts.state, facts.start_time,
                        facts.trials, facts.valid_trials, facts.planned_trials,
                        facts.comments, facts.parameters, facts.levels, facts.facts)
end

# What the library reads of a stored session: the keys of
# the session file the catalogue depends on, and no reconstruction of what they mean
function stored_session_facts(stored::AbstractDict)
    ex_par = get(stored, "ex_par", Dict{String, Any}())
    stim_par = get(stored, "stim_par", Dict{String, Any}())
    history = something(get(stored, "history", Any[]), Any[])
    raw_tags = something(get(stored, "tags", String[]), String[])
    raw_indep_names = something(get(ex_par, "indep_var_names", String[]), String[])
    indep_var_names = Symbol[Symbol(n) for n in raw_indep_names]
    raw_ranges = something(get(ex_par, "indep_var_ranges", Any[]), Any[])
    raw_comments = something(get(stored, "comments", Any[]), Any[])
    stim_fields = get(stim_par, "fields", Dict{String, Any}())
    return (
        id = String(stored["id"]),
        participant = String(get(stored, "participant_id", "")),
        tags = String[String(t) for t in raw_tags],
        experiment_name = String(get(ex_par, "experiment_name", "")),
        method = String(get(get(stored, "method_instance", Dict{String, Any}()),
                            "_type", "")),
        stimulus = stored_stimulus_name(stim_par),
        indep_var_names = indep_var_names,
        state = session_state(get(stored, "state", "")),
        # An integral unix time is read back as an Int, and a session that was
        # never started has none
        start_time = coerce_field(Union{Nothing, Float64},
                                  get(stored, "start_time", nothing)),
        trials = length(history),
        valid_trials = count(trial -> get(trial, "is_valid", true) === true, history),
        planned_trials = coerce_field(Union{Nothing, Int},
                                      get(stored, "planned_trials", nothing)),
        comments = String[String(c["text"]) for c in raw_comments],
        parameters = Dict{Symbol, Any}(Symbol(name) => fact_value(value)
                                       for (name, value) in stim_fields),
        levels = Dict{Symbol, Vector{Any}}(
            name => Any[fact_value(v) for v in range]
            for (name, range) in zip(indep_var_names, raw_ranges)),
        facts = stored_combining_facts(stored, COMBINING_CHECKS),
    )
end

# The stimulus a stored session presents, as `stimulus_name` gives it: a worker's
# stimulus by the name the worker declares
stored_stimulus_name(stored::AbstractDict) =
    get(stored, "_type", "") == "WorkerStimulus" ? String(get(stored, "stimulus", "")) :
                                                   String(get(stored, "_type", ""))

# ── Session series ───────────────────────────────────────────────────────────

"""
    SessionSeries

A group of sessions of one participant in one experiment that measured the same thing
in the same way — the repetitions of one measurement condition, grouped under the same
facts an [`AnalysisSet`](@ref) compares and any `key:value` tags.
"""
struct SessionSeries
    participant::String
    experiment_name::String
    facts::Vector{Pair{Symbol, Any}}
    tag_values::Dict{String, String}
    entries::Vector{LibraryEntry}
end

Base.:(==)(a::SessionSeries, b::SessionSeries) =
    all(field -> getfield(a, field) == getfield(b, field), fieldnames(SessionSeries))

Base.isequal(a::SessionSeries, b::SessionSeries) =
    all(field -> isequal(getfield(a, field), getfield(b, field)), fieldnames(SessionSeries))

function Base.hash(series::SessionSeries, h::UInt)
    h = hash(:SessionSeries, h)
    for field in fieldnames(SessionSeries)
        h = hash(getfield(series, field), h)
    end
    return h
end

function Base.show(io::IO, series::SessionSeries)
    n = length(series.entries)
    trials = sum(entry -> entry.trials, series.entries; init = 0)
    valid_trials = sum(entry -> entry.valid_trials, series.entries; init = 0)
    print(io, series.participant, "  ", series.experiment_name, "  ",
          n == 1 ? "1 session" : "$n sessions", "  ",
          valid_trials, "/", trials, " trials")
end

function Base.show(io::IO, ::MIME"text/plain", series::SessionSeries)
    show(io, series)
    if !isempty(series.tag_values)
        pairs_text = ["$k:$v" for (k, v) in sort!(collect(series.tag_values); by = first)]
        print(io, "\n  tags: ", join(pairs_text, ", "))
    end
    for entry in series.entries
        print(io, "\n  ", basename(entry.path))
    end
end

function parse_tag_values(tags::AbstractVector{<:AbstractString})
    values = Dict{String, String}()
    for tag in tags
        parts = split(tag, ':'; limit = 2)
        length(parts) == 2 || continue
        key, val = parts[1], parts[2]
        (isempty(key) || isempty(val)) && continue
        values[String(key)] = String(val)
    end
    return values
end

function narrow_facts(facts::Vector{Pair{Symbol, Any}}, checks::Vector{Symbol})
    return Pair{Symbol, Any}[pair for pair in facts
                              if first(pair) in ALWAYS_COMBINING_FACTS ||
                                 first(pair) in checks]
end

"""
    browse_series(directory = resolve_data_dir();
                  checks = load_combining_checks(directory),
                  filters...) -> Vector{SessionSeries}

Groups the session files of `directory` into [`SessionSeries`](@ref) — one per
participant, experiment name, compared facts under `checks`, and `key:value` tags.
`filters...` are forwarded to [`browse_sessions`](@ref); combined datasets are left out.

Series are ordered by the start time of their first session (never-started last), then
by its file path, and each series keeps its sessions in `browse_sessions` order.
"""
function validate_combining_checks(checks)
    unknown = [check for check in checks if !(check in COMBINING_CHECKS)]
    isempty(unknown) || throw(ArgumentError(
        "$(join(repr.(unknown), ", ")) is not a combining check; the checks are " *
        "$(join(repr.(COMBINING_CHECKS), ", "))."))
    return Symbol[check for check in COMBINING_CHECKS if check in checks]
end

function group_series(entries::AbstractVector{LibraryEntry}; checks = COMBINING_CHECKS)
    active_checks = validate_combining_checks(checks)
    grouped = Dict{Any, SessionSeries}()
    series_list = SessionSeries[]
    for entry in entries
        entry.kind === :session || continue
        participant = only(entry.participants)
        narrowed = narrow_facts(entry.facts, active_checks)
        tag_vals = parse_tag_values(entry.tags)
        key = (participant, entry.experiment_name, narrowed, tag_vals)
        if haskey(grouped, key)
            push!(grouped[key].entries, entry)
        else
            series = SessionSeries(participant, entry.experiment_name, narrowed,
                                   tag_vals, LibraryEntry[entry])
            grouped[key] = series
            push!(series_list, series)
        end
    end

    for series in series_list
        sort!(series.entries; by = entry_sort_key)
    end
    return sort!(series_list; by = s -> entry_sort_key(first(s.entries)))
end

function browse_series(directory::AbstractString = resolve_data_dir();
                       checks = load_combining_checks(String(directory)),
                       filters...)
    validate_combining_checks(checks)
    entries = browse_sessions(directory; filters...)
    return group_series(entries; checks)
end

struct Absent end
const ABSENT = Absent()

function find_series_fact(series::SessionSeries, name::Symbol)
    for (fact_name, value) in series.facts
        fact_name === name && return value
    end
    return ABSENT
end

function all_isequal(values)
    first_val = first(values)
    return all(v -> isequal(v, first_val), Iterators.drop(values, 1))
end

"""
    session_variables(series::AbstractVector{SessionSeries}) ->
        (parameters = Vector{Symbol}, tags = Vector{String}, other = Vector{Symbol})

What differs between the given `series`: `parameters` names the stimulus parameters in the
`:stimulus` fact whose values are not all equal (sorted), `tags` names the `key:value`
tag keys whose values are not all equal (sorted), and `other` names the other facts in
`facts` order whose values are not all equal. Fewer than two series returns all three empty.
"""
function session_variables(series::AbstractVector{SessionSeries})
    length(series) < 2 &&
        return (parameters = Symbol[], tags = String[], other = Symbol[])

    stim_dicts = [find_series_fact(s, :stimulus) for s in series]
    param_names = sort!(unique(String[
        string(k) for d in stim_dicts if d isa AbstractDict for k in keys(d)]))
    parameters = Symbol[
        Symbol(pname) for pname in param_names
        if !all_isequal(d isa AbstractDict ? get(d, pname, ABSENT) : ABSENT
                        for d in stim_dicts)]

    tag_keys = sort!(unique(String[k for s in series for k in keys(s.tag_values)]))
    tags = String[
        k for k in tag_keys
        if !all_isequal(get(s.tag_values, k, ABSENT) for s in series)]

    other_names = Symbol[]
    for s in series, (name, _) in s.facts
        name === :stimulus && continue
        name in other_names || push!(other_names, name)
    end
    other = Symbol[
        name for name in other_names
        if !all_isequal(find_series_fact(s, name) for s in series)]

    return (parameters = parameters, tags = tags, other = other)
end

"""
    AnalysisSet(entries::AbstractVector{LibraryEntry}; checks = load_combining_checks())

Combines what [`browse_sessions`](@ref) listed, in one call:

```julia
set = AnalysisSet(browse_sessions(; tags = "pilot"))
```

The files are loaded in the order of `entries`, a dataset contributing its members. A
session listed more than once — saved as its own file and in a dataset — is taken once,
without a warning; every other refusal is warned on as [`add_session!`](@ref) does.
"""
function AnalysisSet(entries::AbstractVector{LibraryEntry}; checks = load_combining_checks())
    sessions = SessionContext[]
    for entry in entries
        loaded = entry.kind === :set ? load_analysis_set(entry.path).sessions :
                                       [load_session(entry.path)]
        append!(sessions, loaded)
    end
    return AnalysisSet(unique(session -> session.id, sessions); checks)
end

# ── Discarded sessions ───────────────────────────────────────────────────────

"""
    DISCARDED_DIRECTORY

The name of the directory a discarded file is set aside in, beside the place it was
saved: `data/P01_….json` is discarded to `data/discarded/P01_….json`.
"""
const DISCARDED_DIRECTORY = "discarded"

"""
    is_discarded(path) -> Bool

Whether `path` lies in a directory of discarded files ([`discard_session`](@ref)).
`nothing`, the path of a session never saved, is not discarded.
"""
is_discarded(path::AbstractString) = basename(dirname(abspath(path))) == DISCARDED_DIRECTORY
is_discarded(::Nothing) = false

"""
    discard_session(path) -> String
    discard_session(session) -> Union{Nothing, String}

Sets aside a session that should not be kept — a test run, a false start — and returns
where it now is. Its file moves into the [`DISCARDED_DIRECTORY`](@ref) beside it, where
[`browse_sessions`](@ref) does not look and an [`AnalysisSet`](@ref) refuses it. Nothing
is deleted: [`restore_discarded`](@ref) moves the file back, and emptying the directory
is the operator's own deletion. A combined dataset is discarded the same way.

Given a session, one still running or paused is aborted first — a session thrown away
is not to be continued — and its later checkpoints follow the file, so a trial that
ends after the discard is written beside the rest instead of recreating the file. A
session that has no file yet is only aborted, and `nothing` is returned.

A file is never overwritten: a discarded file of the same name already set aside is a
refusal.
"""
function discard_session(path::AbstractString)
    isfile(path) || throw(ArgumentError("There is no file $path to discard."))
    is_discarded(path) && throw(ArgumentError("$path is discarded already."))
    library_entry(path) === nothing && throw(ArgumentError(
        "$path is neither a session nor a dataset, so it is not discarded."))
    target = joinpath(dirname(abspath(path)), DISCARDED_DIRECTORY, basename(path))
    ispath(target) && throw(ArgumentError(
        "$target already holds a discarded file of that name; nothing was moved."))
    mkpath(dirname(target))
    mv(path, target)
    return target
end

function discard_session(session::SessionContext)
    (session.state == RUNNING || session.state == PAUSED) && abort!(session)
    session.save_path === nothing && return nothing
    is_discarded(session.save_path) && return session.save_path
    session.save_path = discard_session(session.save_path)
    return session.save_path
end

"""
    restore_discarded(path) -> String

Moves a discarded file ([`discard_session`](@ref)) back to the directory it was set
aside from, and returns its path there. A file that exists at that place is never
overwritten.
"""
function restore_discarded(path::AbstractString)
    isfile(path) || throw(ArgumentError("There is no file $path to restore."))
    is_discarded(path) || throw(ArgumentError(
        "$path is not in a $(DISCARDED_DIRECTORY) directory; only a discarded file is restored."))
    target = joinpath(dirname(dirname(abspath(path))), basename(path))
    ispath(target) && throw(ArgumentError(
        "$target exists; restoring $path would overwrite it."))
    mv(path, target)
    return target
end

# ── Labels of saved sessions ───────────────────────────────────────────

"""
    relabel_sessions!(paths; add_tags = String[], remove_tags = String[],
                      comment = nothing, experiment_name = nothing) -> Vector{String}
    relabel_sessions!(entries::AbstractVector{LibraryEntry}; kwargs...) -> Vector{String}

Changes the labels of several saved session files at once and returns the paths of the
files that were rewritten.

Labels — tags, comments and the experiment name — say how a session is filed, not what
it measured; nothing else in the files changes. `add_tags` are appended in the order
given when not already present, `remove_tags` are dropped, `comment` is added as a
whole-session note, and `experiment_name` replaces the stored experiment name.

Every change to a file's tags or experiment name is recorded in that file as a
program-written comment (after `comment`, if one was given), so the change stays in the
session and its exports. A file whose labels do not change is left untouched and omitted
from the returned list.

All files are checked before any is written: unreadable files, non-session files,
combined datasets ([`AnalysisSet`](@ref)) and discarded files ([`is_discarded`](@ref))
are refused, and a failed write restores the files already rewritten.

A session running in a dashboard or loop should be relabelled through the session itself,
not through its file on disk, which the next checkpoint would overwrite.
"""
function relabel_sessions!(paths::AbstractVector{<:AbstractString};
                           add_tags = String[],
                           remove_tags = String[],
                           comment::Union{Nothing, AbstractString} = nothing,
                           experiment_name::Union{Nothing, AbstractString} = nothing)
    isempty(paths) && throw(ArgumentError(
        "Give at least one session file path to relabel."))

    to_add = normalize_relabel_tags(add_tags, "add_tags")
    to_remove = normalize_relabel_tags(remove_tags, "remove_tags")
    overlap = intersect(to_add, to_remove)
    isempty(overlap) || throw(ArgumentError(
        "The same tag cannot be both added and removed: $(join(overlap, ", "))."))

    note = if comment === nothing
        nothing
    else
        trimmed = strip(comment)
        isempty(trimmed) && throw(ArgumentError("A comment cannot be empty."))
        String(trimmed)
    end

    target_name = if experiment_name === nothing
        nothing
    else
        trimmed = strip(experiment_name)
        isempty(trimmed) && throw(ArgumentError("An experiment name cannot be empty."))
        String(trimmed)
    end

    isempty(to_add) && isempty(to_remove) && note === nothing && target_name === nothing &&
        throw(ArgumentError(
            "Nothing to relabel: pass add_tags, remove_tags, comment or experiment_name."))

    unique_paths = deduplicate_paths(paths)
    planned = Tuple{String, Vector{UInt8}, Dict{String, Any}}[]
    for path in unique_paths
        original_bytes, document = read_session_for_relabelling(path)
        if apply_relabel!(document, to_add, to_remove, note, target_name)
            push!(planned, (path, original_bytes, document))
        end
    end

    rewritten = Tuple{String, Vector{UInt8}}[]
    for (path, original_bytes, document) in planned
        try
            atomic_write(io -> JSON3.write(io, document), path)
            push!(rewritten, (path, original_bytes))
        catch
            for (prev_path, prev_bytes) in Iterators.reverse(rewritten)
                try
                    atomic_write(io -> write(io, prev_bytes), prev_path)
                catch restore_err
                    @warn "Could not restore $prev_path after a write failure" exception = restore_err
                end
            end
            rethrow()
        end
    end

    return String[path for (path, _, _) in planned]
end

relabel_sessions!(entries::AbstractVector{LibraryEntry}; kwargs...) =
    relabel_sessions!(String[entry.path for entry in entries]; kwargs...)

function normalize_relabel_tags(tags, role::AbstractString)
    raw = tags isa AbstractString ? (tags,) : tags
    result = String[]
    for tag in raw
        tag isa AbstractString || throw(ArgumentError(
            "Each tag in $role must be a string, got $(typeof(tag))."))
        isempty(strip(tag)) && throw(ArgumentError(
            "A tag in $role cannot be empty."))
        push!(result, String(strip(tag)))
    end
    return result
end

function deduplicate_paths(paths::AbstractVector{<:AbstractString})
    seen = Set{String}()
    unique_paths = String[]
    for raw_path in paths
        path = String(raw_path)
        canonical = abspath(path)
        canonical in seen && continue
        push!(seen, canonical)
        push!(unique_paths, path)
    end
    return unique_paths
end

function read_session_for_relabelling(path::String)
    isfile(path) || throw(ArgumentError("Cannot read session file $path."))
    is_discarded(path) && throw(ArgumentError(
        "$path is a discarded file; restore it before relabelling."))

    original_bytes = try
        read(path)
    catch err
        throw(ArgumentError("Cannot read session file $path: $(sprint(showerror, err))."))
    end

    document = try
        JSON3.read(String(copy(original_bytes)), Dict{String, Any})
    catch err
        throw(ArgumentError(
            "$path is not a valid JSON session file: $(sprint(showerror, err))."))
    end

    is_analysis_set_document(document) && throw(ArgumentError(
        "$path holds a combined dataset, not a session file."))
    (haskey(document, "tags") && document["tags"] isa AbstractVector &&
     all(tag -> tag isa AbstractString, document["tags"]) &&
     haskey(document, "ex_par") && document["ex_par"] isa AbstractDict &&
     haskey(document["ex_par"], "experiment_name") &&
     document["ex_par"]["experiment_name"] isa AbstractString &&
     (!haskey(document, "comments") || document["comments"] isa AbstractVector)) ||
        throw(ArgumentError("$path is not a session file."))

    return (original_bytes, document)
end

function apply_relabel!(document::Dict{String, Any},
                        to_add::Vector{String},
                        to_remove::Vector{String},
                        note::Union{Nothing, String},
                        target_name::Union{Nothing, String})
    tags = String[String(tag) for tag in document["tags"]]
    added = String[]
    for tag in to_add
        if !(tag in tags)
            push!(tags, tag)
            push!(added, tag)
        end
    end
    removed = String[]
    for tag in to_remove
        if tag in tags
            filter!(!=(tag), tags)
            push!(removed, tag)
        end
    end

    ex_par = document["ex_par"]
    old_name = String(ex_par["experiment_name"])
    name_changed = target_name !== nothing && target_name != old_name

    parts = String[]
    isempty(added) || push!(parts, "tags added: " * join(added, ", "))
    isempty(removed) || push!(parts, "tags removed: " * join(removed, ", "))
    name_changed && push!(parts, "experiment name: \"$old_name\" → \"$target_name\"")

    isempty(parts) && note === nothing && return false

    if !isempty(added) || !isempty(removed)
        document["tags"] = tags
    end
    if name_changed
        ex_par["experiment_name"] = target_name
    end

    comments = get!(document, "comments") do
        Any[]
    end
    if note !== nothing
        push!(comments, Dict{String, Any}("time" => time(), "trial" => nothing,
                                          "text" => note))
    end
    if !isempty(parts)
        push!(comments, Dict{String, Any}("time" => time(), "trial" => nothing,
                                          "text" => "Relabelled: " * join(parts, "; ")))
    end
    return true
end
