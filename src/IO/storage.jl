# Session persistence: the JSON checkpoint written after every trial and the
# filenames it is written under. Installation
# configuration (`settings.toml`) is loaded in `settings.jl`.

# Bumped on structural changes to the session-file layout. Before 1.0 there is
# no migration machinery: the loader only refuses files from a newer schema than
# it understands.
const SESSION_SCHEMA_VERSION = 1

# ── Token resolution ─────────────────────────────────────────────────────────

"""
    resolve_token(token, session, config) -> String

Resolve a single template token to its string value from the session data.

Supported tokens:
- `{participant_id}` — participant identifier
- `{method}`         — psychophysical method name
- `{indep_vars}`     — independent variable names joined by separator
- `{tags}`           — session tags joined by `_`
- `{timestamp}`      — date/time stamp (session start time or current time)
- `{session_id}`     — full UUID
- `{short_id}`       — first 8 characters of UUID
- `{stim_par.<field>}` — any stimulus parameter field (e.g. `stim_par.Ref`)
- `{ex_par.<field>}`   — any experiment parameter field (e.g. `ex_par.repeats`)
"""
function resolve_token(token::String, session::SessionContext, config::Dict{String,Any})
    token == "participant_id" && return session.participant_id
    token == "method"         && return type_name(session.method_instance)
    token == "tags"           && return join(session.tags, "_")
    token == "session_id"     && return string(session.id)
    token == "short_id"       && return string(session.id)[1:8]

    if token == "indep_vars"
        sep = get(config, "indep_vars_separator", "&")
        return join(string.(session.ex_par.indep_var_names), sep)
    end

    if token == "timestamp"
        fmt = get(config, "timestamp_format", "yyyy-mm-dd_HH-MM-SS")
        dt = session.start_time !== nothing ? unix2datetime(session.start_time) : now()
        return Dates.format(dt, fmt)
    end

    if startswith(token, "stim_par.")
        field = Symbol(token[length("stim_par.")+1:end])
        has_parameter(session.stim_par, field) &&
            return string(parameter_value(session.stim_par, field))
        @warn "Stimulus parameter '$field' not found in $(stimulus_name(session.stim_par))"
        return "{$token}"
    end

    if startswith(token, "ex_par.")
        field = Symbol(token[length("ex_par.")+1:end])
        try
            return string(getfield(session.ex_par, field))
        catch
            @warn "Experiment parameter '$field' not found"
            return "{$token}"
        end
    end

    @warn "Unknown filename template token: {$token}"
    return "{$token}"
end

# ── Filename generation ──────────────────────────────────────────────────────

# File-system-unsafe characters in resolved token values (path separators,
# Windows-reserved and control characters) become '_', so a participant id
# or tag can neither escape the target directory nor produce an invalid name
sanitize_token_value(s::AbstractString) = replace(s, r"[\x00-\x1f/\\:*?\"<>|]" => "_")

"""
    generate_session_filename(session::SessionContext, config::Dict{String,Any}) -> String

Build a relative file path (possibly with folders separated by `/`) by expanding
`{...}` tokens in the template from `config`. Resolved token values are sanitized for
file-system safety, so only the template's own `/` creates folders; a template whose
expanded path starts with `/` or contains an empty, `.` or `..` segment is refused.
"""
function generate_session_filename(session::SessionContext, config::Dict{String,Any})
    template = get(config, "filename_template", DEFAULT_STORAGE_CONFIG["filename_template"])

    result = replace(template, r"\{([^}]+)\}" => m -> begin
        token = String(m)[2:end-1]
        sanitize_token_value(resolve_token(token, session, config))
    end)

    segments = split(result, '/')
    (startswith(result, "/") || any(seg -> isempty(seg) || seg == "." || seg == "..", segments)) &&
        throw(ArgumentError(
            "Filename template '$template' must expand to a relative path without empty, '.' or '..' segments."))

    return result * ".json"
end

"""
    generate_session_filename(session::SessionContext, directory::String=".") -> String

Convenience method: automatically loads `settings.toml` from `directory`
up through the directory tree.
"""
function generate_session_filename(session::SessionContext, directory::String=".")
    config = load_storage_config(directory)
    return generate_session_filename(session, config)
end

# ── Save / Load ──────────────────────────────────────────────────────────────

# JSON has no NaN, so the presentation a participant never answered
# (MISSING_RESPONSE) is written as `null`, the same way an unscored
# `correct` is. The response window that closed before an answer arrived
# is written as the string "timeout", which no number and no null can be
# confused with — the record must say which of the two happened.
response_to_json(response::Real) = isnan(response) ? nothing : response
response_to_json(response::Symbol) = string(response)
response_from_json(::Nothing) = MISSING_RESPONSE
response_from_json(response::Real) = response

function response_from_json(response::AbstractString)
    response == "timeout" || throw(ArgumentError(
        "A stored response is a number, null, or \"timeout\", got " *
        "\"$response\"."))
    return :timeout
end

# A method field is stored only when the session file can represent it and
# `coerce_field` can read it back. Anything else — an adaptive method's
# posterior, a handle to a library object — is stored as `null` and rebuilt by
# `restore_method_state!` on load, because a file holding one library
# version's internals would not be readable by the next.
is_storable(::Union{Nothing, Real, AbstractString, Symbol}) = true
is_storable(value::Union{AbstractVector, Tuple}) = all(is_storable, value)
is_storable(::Any) = false

method_field_to_json(value) = is_storable(value) ? value : nothing

# A method may own other methods — the tracks of an interleaved run — and those
# are written as sub-methods, through the same registry, so a track keeps its
# own type and configuration instead of being flattened into its owner's fields
method_field_to_json(methods::AbstractVector{<:AbstractPsychoMethod}) =
    [method_to_dict(method) for method in methods]

"""
    method_to_dict(method) -> Dict
    method_from_dict(d) -> AbstractPsychoMethod

The stored form of a method and its way back: the registered type name and
the fields the file can hold, with whatever the method keeps outside them
rebuilt by [`restore_method_state!`](@ref) once the fields are in place.
"""
method_to_dict(method::AbstractPsychoMethod) = Dict{String, Any}(
    "_type" => type_name(method),
    "fields" => Dict(string(name) => method_field_to_json(getfield(method, name))
                     for name in fieldnames(typeof(method))),
)

function method_from_dict(d)
    method_type = registered_type(METHOD_REGISTRY, "method", Symbol(d["_type"]),
        "Custom types must be registered with PsychophysicsManager.register_method_type! before loading.")

    method = method_type()
    for (key, value) in d["fields"]
        field_sym = Symbol(key)
        hasfield(method_type, field_sym) || continue
        field_type = fieldtype(method_type, field_sym)
        restored = coerce_field(field_type, value)
        # A field stored as `null` that cannot hold one was never saved (it is
        # runtime state); leave the fresh instance's own value in place
        restored === nothing && !(field_type >: Nothing) && continue
        setfield!(method, field_sym, restored)
    end
    restore_method_state!(method)
    return method
end

"""
    task_to_dict(task) -> Union{Nothing, Dict}
    task_from_dict(d) -> Union{Nothing, ObserverTask}

The stored form of a session's [`ObserverTask`](@ref), and its way back. A
session that declared none stores `nothing`.
"""
task_to_dict(::Nothing) = nothing
task_to_dict(task::ObserverTask) = Dict{String, Any}(
    "instructions" => task.instructions,
    "options" => collect(task.options),
    "positive_option" => task.positive_option,
)

task_from_dict(::Nothing) = nothing
function task_from_dict(d::AbstractDict)
    options = String.(d["options"])
    return ObserverTask(d["instructions"], (options[1], options[2]), d["positive_option"])
end

"""
    messages_to_dict(messages) -> Dict
    messages_from_dict(d) -> SessionMessages

The stored form of a session's [`SessionMessages`](@ref), and its way back through the
validating constructor.
"""
function messages_to_dict(m::SessionMessages)
    return Dict{String, Any}(
        "instructions" => m.instructions,
        "break_every" => m.break_every,
        "break_after" => m.break_after,
        "break_waits_for" => string(m.break_waits_for),
        "break_min_s" => m.break_min_s,
        "break_text" => m.break_text,
        "closing_text" => m.closing_text,
    )
end

function messages_from_dict(d::Union{Nothing, AbstractDict})
    d === nothing && return SessionMessages()
    return SessionMessages(
        instructions = Bool(get(d, "instructions", false)),
        break_every = Int(get(d, "break_every", 0)),
        break_after = Int[Int(x) for x in get(d, "break_after", Int[])],
        break_waits_for = Symbol(get(d, "break_waits_for", "participant")),
        break_min_s = Float64(get(d, "break_min_s", 0.0)),
        break_text = String(get(d, "break_text", "")),
        closing_text = String(get(d, "closing_text", "")),
    )
end

"""
    unit_conversions_to_dict(conversions) -> Dict
    unit_conversions_from_dict(d) -> Dict{Symbol, UnitConversion}

The stored form of a session's [`UnitConversion`](@ref)s, keyed by variable name, and
its way back through the validating constructor.
"""
function unit_conversion_to_dict(conversion::UnitConversion)
    entry = Dict{String, Any}(
        "label" => conversion.label,
        "form" => string(conversion.form),
        "scale" => conversion.scale,
        "offset" => conversion.offset,
    )
    isempty(conversion.formula) || (entry["formula"] = conversion.formula)
    return entry
end

unit_conversions_to_dict(conversions::AbstractDict{Symbol, UnitConversion}) =
    Dict{String, Any}(string(variable) => unit_conversion_to_dict(conversion)
                      for (variable, conversion) in conversions)

unit_conversions_from_dict(d::AbstractDict) =
    Dict{Symbol, UnitConversion}(
        Symbol(variable) => UnitConversion(stored["label"], Symbol(stored["form"]),
                                           stored["scale"], stored["offset"],
                                           String(something(get(stored, "formula", ""), "")))
        for (variable, stored) in d)

"""
    session_state(name) -> SessionState

The lifecycle state a stored session names. A name this version does not know is
refused rather than guessed: it means a corrupted file or one written by an
incompatible version.
"""
function session_state(name::AbstractString)
    state_sym = Symbol(name)
    state = isdefined(PsychophysicsManager, state_sym) ? getfield(PsychophysicsManager, state_sym) : nothing
    state isa SessionState ||
        error("Unknown session state '$name' in the file — it may be corrupted or " *
              "written by an incompatible version.")
    return state
end

"""
    session_to_dict(s::SessionContext) -> Dict

Converts a SessionContext into a plain Julia Dictionary for JSON serialization.
"""
function session_to_dict(s::SessionContext)
    return Dict{String, Any}(
        "schema_version" => SESSION_SCHEMA_VERSION,
        "id" => string(s.id),
        "participant_id" => s.participant_id,
        "tags" => s.tags,
        "start_time" => s.start_time,
        "program_version" => s.program_version,
        "state" => string(s.state),
        "engine_name" => s.engine_name,
        "fit_gamma" => s.fit_gamma,
        "feedback" => s.feedback,
        "timeout_s" => s.timeout_s,
        "min_response_s" => s.min_response_s,
        "rig" => s.rig,
        "messages" => messages_to_dict(s.messages),
        "unit_conversions" => unit_conversions_to_dict(s.unit_conversions),
        # A decimal string, not a JSON number: a UInt64 seed does not fit the
        # signed integers JSON readers agree on
        "rng_seed" => string(s.rng_seed),
        "rng_state" => rng_state(s.rng),
        "environment" => s.environment,
        "comments" => [Dict{String, Any}("time" => c.time, "trial" => c.trial,
                                         "text" => c.text) for c in s.comments],
        "task" => task_to_dict(s.task),
        "observer_metadata" => s.observer_metadata,
        "ex_par" => Dict(
            "experiment_name" => s.ex_par.experiment_name,
            "indep_var_names" => string.(s.ex_par.indep_var_names),
            "indep_var_ranges" => [collect(r) for r in s.ex_par.indep_var_ranges],
            "repeats" => s.ex_par.repeats
        ),
        "stim_par" => stimulus_to_dict(s.stim_par),
        "method_instance" => method_to_dict(s.method_instance),
        "adjusted_fields" => string.(adjusted_fields(s.method_instance)),
        # NOTE: `listeners` is runtime-only and intentionally not serialized
        "current_trial_idx" => s.current_trial_idx,
        "planned_trials" => planned_valid_trials(s),
        "history" => [
            Dict(
                "trial_index" => t.trial_index,
                "timestamp_onset" => t.timestamp_onset,
                "timestamp_response" => t.timestamp_response,
                "indep_var_vals" => t.indep_var_vals,
                "response" => response_to_json(t.response),
                "correct" => t.correct,
                "is_valid" => t.is_valid,
                "onset_source" => string(t.onset_source),
                "origin" => string(t.origin),
                "start_value" => t.start_value
            ) for t in s.history
        ]
    )
end

# A stimulus as a session file holds it: its type and its fields
stimulus_to_dict(stim_par::AbstractStimulusParameters) = Dict{String, Any}(
    "_type" => type_name(stim_par),
    "fields" => Dict(string(n) => getfield(stim_par, n) for n in fieldnames(typeof(stim_par))))

# A worker's stimulus keeps its parameters in `fields` as a worker receives them, its
# name beside them, and their order, which a JSON object does not keep, in `parameters`
stimulus_to_dict(stim_par::WorkerStimulus) = Dict{String, Any}(
    "_type" => type_name(stim_par),
    "stimulus" => stim_par.stimulus,
    "parameters" => string.(parameter_names(stim_par)),
    "fields" => Dict(string(name) => value for (name, value) in stim_par.parameters))

function worker_stimulus_from_dict(stored::AbstractDict)
    stimulus = get(stored, "stimulus", nothing)
    names = get(stored, "parameters", nothing)
    fields = get(stored, "fields", nothing)
    (stimulus isa AbstractString && names isa AbstractVector && fields isa AbstractDict &&
     Set(String.(names)) == Set(String.(keys(fields)))) || error(
        "The session file's WorkerStimulus is not one PsychophysicsManager wrote: it names its " *
        "stimulus, lists its parameters in order, and gives each a value in fields.")
    return WorkerStimulus(stimulus, [name => fields[name] for name in names])
end

"""
    coerce_field(T::Type, v)

Convert a JSON-parsed value `v` to the declared field type `T`. Handles the
representations JSON cannot preserve natively: symbols, tuples, typed vectors,
unsigned integers written as strings, and `Union{Nothing, ...}` fields.
"""
function coerce_field(T::Type, v)
    v === nothing && return nothing
    T === Any && return v
    v isa T && return v

    # Unwrap Union{Nothing, X}
    if T isa Union
        inner = T.a === Nothing ? T.b : T.a
        return coerce_field(inner, v)
    end

    # Values above typemax(Int64) — an RNG seed, a hash — are written as
    # strings, because a JSON reader has only signed integers to offer
    T <: Unsigned && v isa AbstractString && return parse(T, v)
    T <: Symbol && return Symbol(v)
    T <: Tuple  && return T(v)
    if T <: AbstractVector
        # Constructors (not broadcasts) so that empty Vector{Any} from JSON
        # still converts to the declared element type
        ET = eltype(T)
        # A method that owns methods gets them back through the registry, each
        # rebuilding its own runtime state as it is read
        ET <: AbstractPsychoMethod && return T(map(method_from_dict, v))
        ET <: AbstractVector && return T(map(x -> Vector{eltype(ET)}(x), v))
        ET === Symbol        && return T(map(Symbol, v))
        return T(v)
    end

    return convert(T, v)
end

"""
    obsolete_stimulus_fields(document::AbstractDict) -> Vector{Pair{String, Any}}

The stimulus parameters a session file sets that its stimulus type no longer has, as
`name => value`. They are left out when the session is read, so the stimulus
program's own list of parameters decides; a combined dataset's are those of its last
session, the one a new experiment starts from.
"""
function obsolete_stimulus_fields(document::AbstractDict)
    stored = haskey(document, "sessions") ? last(document["sessions"]) : document
    stimulus = get(stored, "stim_par", nothing)
    stimulus isa AbstractDict || return Pair{String, Any}[]
    type = get(STIMULUS_REGISTRY, Symbol(get(stimulus, "_type", "")), nothing)
    # A worker's stimulus is completed to what the worker declares when a session starts
    (type === nothing || type === WorkerStimulus) && return Pair{String, Any}[]
    return Pair{String, Any}[String(name) => value
                             for (name, value) in get(stimulus, "fields", Dict())
                             if !hasfield(type, Symbol(name))]
end

"""
    dict_to_session(d::Dict) -> SessionContext

Reconstructs a SessionContext from a parsed JSON dictionary.
"""
function dict_to_session(d::Dict)
    # Refuse files written by a newer schema; absence of the key means an
    # older (pre-versioning) file and is tolerated
    file_schema = get(d, "schema_version", 1)
    file_schema <= SESSION_SCHEMA_VERSION ||
        error("Session file uses schema version $file_schema, but this PsychophysicsManager " *
              "understands up to $SESSION_SCHEMA_VERSION — upgrade the package to load it.")

    # Parse ex_par
    ex_par = ExperimentParameters(
        d["ex_par"]["experiment_name"],
        Symbol.(d["ex_par"]["indep_var_names"]),
        Vector{Any}(d["ex_par"]["indep_var_ranges"]),
        d["ex_par"]["repeats"]
    )

    # Parse stim_par (types come from the registry)
    stim_type = registered_type(STIMULUS_REGISTRY, "stimulus parameter",
        Symbol(d["stim_par"]["_type"]),
        "Custom types must be registered with PsychophysicsManager.register_stimulus_type! before loading.")

    stim_fields_dict = d["stim_par"]["fields"]
    obsolete = obsolete_stimulus_fields(d)
    isempty(obsolete) || @warn "The session file sets " *
        "$(join(("$name = $(repr(value))" for (name, value) in obsolete), ", ")), which " *
        "$(nameof(stim_type)) no longer has; the stimulus program's own parameters decide, " *
        "and these are left out."
    if stim_type === WorkerStimulus
        stim_par = worker_stimulus_from_dict(d["stim_par"])
    elseif stim_type === BaseStimulusParameters
        stim_par = BaseStimulusParameters(stim_fields_dict["duration_ms"])
    else
        # Assume kwdef-constructible from its fields; unknown fields in old
        # files are skipped (same courtesy as for method fields below)
        stim_kwargs = Dict(Symbol(k) => coerce_field(fieldtype(stim_type, Symbol(k)), v)
                           for (k, v) in stim_fields_dict if hasfield(stim_type, Symbol(k)))
        stim_par = stim_type(; stim_kwargs...)
    end

    method_instance = method_from_dict(d["method_instance"])

    # Parse history
    history = Trial[]
    for td in d["history"]
        push!(history, Trial(
            td["trial_index"],
            td["timestamp_onset"],
            td["timestamp_response"],
            Float64.(td["indep_var_vals"]),
            response_from_json(td["response"]),
            td["is_valid"],
            Symbol(get(td, "onset_source", "estimated")),
            get(td, "correct", nothing),
            Symbol(get(td, "origin", "method")),
            coerce_field(Union{Nothing, Float64}, get(td, "start_value", nothing))
        ))
    end

    # A file that recorded no seed cannot describe its own randomization; the
    # session gets a fresh one, which only affects what it would run next
    seed = something(coerce_field(UInt64, get(d, "rng_seed", nothing)), draw_rng_seed())

    state = session_state(d["state"])

    return SessionContext(
        UUID(d["id"]),
        d["participant_id"],
        String.(d["tags"]),
        d["start_time"],
        d["program_version"],
        state,
        ex_par,
        stim_par,
        history,
        d["current_trial_idx"],
        method_instance,
        task_from_dict(get(d, "task", nothing)),
        get(d, "engine_name", "UnknownEngine"),
        # Additive since schema 1: files written before the setting existed
        # load with the default asymptote rather than being refused
        Float64(get(d, "fit_gamma", DEFAULT_FIT_GAMMA)),
        # Additive since schema 1 too: a file written before feedback could be
        # declared describes a session that gave none
        Bool(get(d, "feedback", false)),
        # Additive since schema 1 as well: a file written before a response
        # window could be declared describes a session that waited
        coerce_field(Union{Nothing, Float64}, get(d, "timeout_s", nothing)),
        Float64(get(d, "min_response_s", 0.0)),
        Dict{String, Any}(get(d, "rig", Dict{String, Any}())),
        # Additive since schema 1 as well: a file written before messages could
        # be declared shows none
        messages_from_dict(get(d, "messages", nothing)),
        # Additive since schema 1 as well: a file written before conversions could
        # be declared shows every value in the units it was recorded in
        unit_conversions_from_dict(get(d, "unit_conversions", Dict{String, Any}())),
        # Additive since schema 1 as well: only sessions answered by a program
        # carry it, and older files load with none
        Dict{String, Any}(get(d, "observer_metadata", Dict{String, Any}())),
        seed,
        Dict{String, String}(get(d, "environment", Dict{String, String}())),
        SessionComment[SessionComment(Float64(c["time"]),
                                      coerce_field(Union{Nothing, Int}, c["trial"]),
                                      String(c["text"]))
                       for c in get(d, "comments", Any[])],
        restore_rng(seed, get(d, "rng_state", nothing)),
        Function[],
        nothing,
        false,
        nothing,
        OperatorRequest[],
        nothing
    )
end

"""
    save_session_checkpoint(session::SessionContext, directory::String="."; filename=nothing)

Serialize the entire `SessionContext` to a JSON file. The write is atomic:
data goes to a temporary file first, which is then renamed over the target,
so a crash mid-write cannot corrupt an existing checkpoint.

The target path is pinned on the session (`session.save_path`) by the first
save or by `load_session`; every later checkpoint rewrites that same file.
Template tokens are therefore evaluated only once per session — mid-session
changes to token values, the working directory, or settings cannot fork the
checkpoints into several files. Passing `filename` explicitly ("save as")
re-pins the path. A freshly generated filename that already belongs to a
*different* session is suffixed with this session's short id instead of
overwriting the existing data.
"""
function save_session_checkpoint(session::SessionContext, directory::String=".";
                                 filename::Union{Nothing, String}=nothing)
    if filename !== nothing
        session.save_path = abspath(joinpath(directory, filename))
    elseif session.save_path === nothing
        config = load_storage_config(directory)
        candidate = joinpath(abspath(directory), generate_session_filename(session, config))
        session.save_path = disambiguate_collision(candidate, session)
    end
    mkpath(dirname(session.save_path))
    dict_repr = session_to_dict(session)
    return atomic_write(session.save_path) do io
        JSON3.write(io, dict_repr)
    end
end

# The position of a session's random stream, as the words of its state: written with
# every checkpoint, so that a session continued from its file draws on from where it
# stopped. Decimal strings for the reason `rng_seed` is one.
rng_state(rng::Xoshiro) = [string(getfield(rng, name)) for name in fieldnames(Xoshiro)]
rng_state(::AbstractRNG) = nothing

# The numbers a stream gives depend on its first four words. Julia 1.11 added a fifth,
# read only when a task is spawned, so a file moves between Julia versions either way.
function restore_rng(seed::UInt64, state)
    state === nothing && return Xoshiro(seed)
    words = UInt64[coerce_field(UInt64, word) for word in state]
    length(words) >= 4 ||
        error("`rng_state` holds $(length(words)) words; a random stream's state has at least 4.")
    return Xoshiro(words[1:min(length(words), fieldcount(Xoshiro))]...)
end

"""
    atomic_write(write_contents, path) -> path

Writes a file so that neither a crash nor a power cut can leave it half-written or
missing: `write_contents(io)` fills a temporary file beside `path`, the file is synced
to the disk, and one rename puts it in the place of `path`.
"""
function atomic_write(write_contents::Function, path::String)
    tmppath = path * ".tmp"
    open(tmppath, "w") do io
        write_contents(io)
        flush(io)
        sync_to_disk(io)
    end
    # Not `mv(…; force = true)`: before Julia 1.12 it deletes the target and then
    # renames, and a crash between the two leaves no file at all
    Base.Filesystem.rename(tmppath, path)
    return path
end

# A rename is durable before the data it names (ext4, NTFS): without the sync a power
# cut after the rename can leave the new name on an empty file. A file system that
# cannot sync (some network mounts) keeps the write and says so once.
function sync_to_disk(io::IOStream)
    status = @static Sys.iswindows() ? ccall(:_commit, Cint, (Cint,), fd(io)) :
                                       ccall(:fsync, Cint, (Cint,), fd(io))
    status == 0 ||
        @warn "A file could not be synced to the disk; a power cut may lose it" maxlog = 1
    return nothing
end

# A generated checkpoint filename must never silently overwrite a different
# session (e.g. same participant + method under a template with no unique
# token). If the candidate file exists and holds another session id — or is
# unreadable — append this session's short id; fall back to the full id in
# the (practically impossible) case that name is taken by a third session.
function disambiguate_collision(filepath::String, session::SessionContext)
    session_owns(filepath) = try
        string(JSON3.read(read(filepath, String), Dict)["id"]) == string(session.id)
    catch
        false
    end

    (!isfile(filepath) || session_owns(filepath)) && return filepath
    stem, ext = splitext(filepath)
    alt = stem * "_" * string(session.id)[1:8] * ext
    if isfile(alt) && !session_owns(alt)
        alt = stem * "_" * string(session.id) * ext
    end
    @warn "Checkpoint filename collision: '$filepath' belongs to another session; " *
          "saving as '$alt'. Add {short_id} or {timestamp} to the filename template " *
          "to avoid this."
    return alt
end

"""
    checkpoint_if_pinned(session::SessionContext)

Rewrites the session's pinned checkpoint file if one exists (best-effort:
failures are logged, never thrown). Used by API commands that mutate history
or reach a terminal state, so the on-disk snapshot cannot silently diverge
from memory. Sessions that were never saved stay memory-only.
"""
function checkpoint_if_pinned(session::SessionContext)
    session.save_path === nothing && return nothing
    try
        save_session_checkpoint(session)
    catch e
        @warn "Failed to update the session checkpoint" exception=(e, catch_backtrace())
    end
    return nothing
end

"""
    load_session(filepath::String) -> SessionContext

Deserialize a `SessionContext` from a JSON checkpoint file. The loaded
session's checkpoint path is pinned to `filepath`, so continuing the session
keeps updating the same file.
"""
function load_session(filepath::String)
    document = read_json_document(filepath)
    is_analysis_set_document(document) && throw(ArgumentError(
        "$filepath holds an analysis set, not a single session; load it with " *
        "load_analysis_set."))
    session = dict_to_session(document)
    session.save_path = abspath(filepath)
    return session
end

# The parsed contents of a JSON file PsychophysicsManager wrote: a session or an analysis set
function read_json_document(filepath::AbstractString)
    isfile(filepath) || error("File not found: $filepath")
    return JSON3.read(read(filepath, String), Dict)
end
