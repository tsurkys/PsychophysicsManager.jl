# Which stimulus program presented a session: found by PsychophysicsManager itself,
# recorded when the session starts, and compared when the session is resumed.

using LibGit2, SHA

"""
    UNKNOWN_STIMULUS_VERSION

What is recorded as the stimulus program's version when it cannot be found. An
unknown version is never compared on resume.
"""
const UNKNOWN_STIMULUS_VERSION = "unknown"

"""
    engine_version(engine::AbstractStimulusEngine) -> Union{String, Nothing}

The version name the author of a stimulus program gives it — `"Oppel-Kundt 2.1"` —
for an engine whose author wants one on record. `start_session!` records it in
`session.environment` as `stimulus_version_stated`, beside the version PsychophysicsManager finds
by itself ([`stimulus_identity`](@ref)), never in its place. The default states none.
"""
engine_version(::AbstractStimulusEngine) = nothing

"""
    stimulus_identity(engine, stim_par) -> (program, version)

The stimulus program presenting `stim_par` on `engine`, as `start_session!` records it
in `session.environment` (`stimulus_program`, `stimulus_version`). The program is the
engine's type and the module defining it; a remote worker is named by its `hello`
reply. The version of a Julia engine is found from the file defining its
`present_stimulus`:

- `"git <commit>, <file> sha256 <hash>"` when that file is in a git repository: the
  commit the repository is at, and the file's own content, which the commit alone does
  not give while the repository holds changes not committed. Such changes are recorded
  as `stimulus_uncommitted_changes`, and are not part of the version, so that an edit
  elsewhere in the repository does not count as a change of the program;
- `"package version <v>"` when the engine is defined in a package outside any
  repository;
- `"sha256 <hash> of <file>"` otherwise, which names no version but shows whether
  the code changed between sessions.

A remote worker's version is the `version` its `hello` reply names. A version that
cannot be found is [`UNKNOWN_STIMULUS_VERSION`](@ref); looking never fails a session.
"""
stimulus_identity(engine::AbstractStimulusEngine, stim_par::AbstractStimulusParameters) =
    find_stimulus(engine, stim_par)[1:2]

# (program, version, uncommitted): what `stimulus_identity` names, and whether the
# repository holding the engine's code had changes not committed
function find_stimulus(engine::AbstractStimulusEngine, stim_par::AbstractStimulusParameters)
    T = typeof(engine)
    version, uncommitted = try
        julia_engine_version(T, stim_par)
    catch
        (UNKNOWN_STIMULUS_VERSION, false)
    end
    return ("$(nameof(T)) ($(nameof(parentmodule(T))))", version, uncommitted)
end

# The git commit comes first: a package under development keeps its version number
# while its code changes
function julia_engine_version(T::Type, stim_par::AbstractStimulusParameters)
    method = which(present_stimulus, Tuple{T, typeof(stim_par), Vector{Float64}})
    file = String(functionloc(method)[1])
    if isfile(file)
        found = git_version(realpath(file))
        found === nothing || return found
    end
    version = pkgversion(parentmodule(T))
    version === nothing || return ("package version $version", false)
    return (isfile(file) ? "sha256 $(file_sha256(file)) of $(basename(file))" :
                           UNKNOWN_STIMULUS_VERSION, false)
end

file_sha256(file::AbstractString) = bytes2hex(open(sha256, file))

# The commit of the repository holding `file` with the file's content, and whether the
# repository holds changes not committed (the file itself uncommitted included), or
# `nothing` outside any repository
function git_version(file::String)
    repo = try
        LibGit2.GitRepoExt(dirname(file))
    catch
        return nothing
    end
    try
        commit = string(LibGit2.head_oid(repo))
        # libgit2 names paths with forward slashes on every system
        path = replace(relpath(file, realpath(LibGit2.path(repo))), '\\' => '/')
        uncommitted = LibGit2.status(repo, path) != 0 || LibGit2.isdirty(repo)
        return ("git $commit, $(basename(file)) sha256 $(file_sha256(file))", uncommitted)
    catch
        return nothing
    finally
        close(repo)
    end
end

"""
    StimulusChangedError

Thrown by [`run_experiment!`](@ref) when a session is resumed under a stimulus program
other than the one that presented it until then (`recorded`, `current`). Running it
again with `accept_changed_stimulus = true` continues it, and the session records the
change; or a new session is started.
"""
struct StimulusChangedError <: Exception
    recorded::String
    current::String
end

Base.showerror(io::IO, err::StimulusChangedError) = print(io,
    "The session was presented by $(err.recorded), and the stimulus program now is " *
    "$(err.current). It does not continue on its own: run it with " *
    "`accept_changed_stimulus = true` to continue under the changed program, which the " *
    "session then records, or start a new session.")

identity_text((program, version)) = "$program, $version"

# The program presenting the session now: the one recorded at its start, or the one a
# deliberate continuation recorded last, from the trial it took effect at
function presenting_stimulus(environment::AbstractDict)
    haskey(environment, "stimulus_version") || return nothing
    changes = Int[]
    for key in keys(environment)
        found = match(r"^stimulus_version_from_trial_(\d+)$", key)
        found === nothing || push!(changes, parse(Int, found[1]))
    end
    isempty(changes) &&
        return (get(environment, "stimulus_program", ""), environment["stimulus_version"])
    trial = maximum(changes)
    return (get(environment, "stimulus_program_from_trial_$trial", ""),
            environment["stimulus_version_from_trial_$trial"])
end

# Records the program presenting the session from its start
function record_stimulus!(environment::AbstractDict, engine::AbstractStimulusEngine,
                          (program, version, uncommitted))
    environment["stimulus_program"] = program
    environment["stimulus_version"] = version
    uncommitted && (environment["stimulus_uncommitted_changes"] = "yes")
    # The engine may be newer than the code recording it (a backend loaded on demand)
    stated = try
        Base.invokelatest(engine_version, engine)
    catch
        nothing
    end
    stated === nothing || (environment["stimulus_version_stated"] = string(stated))
    return environment
end

# A session that has run before is resumed only under the program that presented it:
# a change is refused, or — when accepted — recorded with the first trial it presents.
# A session with no program recorded yet (started before an engine was known, as a
# dashboard does for a script's loop) records this one.
function confirm_stimulus!(session::SessionContext, engine::AbstractStimulusEngine;
                           accept::Bool = false)
    found = find_stimulus(engine, session.stim_par)
    current = found[1:2]
    recorded = presenting_stimulus(session.environment)
    if recorded === nothing
        record_stimulus!(session.environment, engine, found)
    elseif recorded != current && last(recorded) != UNKNOWN_STIMULUS_VERSION &&
           last(current) != UNKNOWN_STIMULUS_VERSION
        accept || throw(StimulusChangedError(identity_text(recorded), identity_text(current)))
        trial = session.current_trial_idx
        session.environment["stimulus_program_from_trial_$trial"] = first(current)
        session.environment["stimulus_version_from_trial_$trial"] = last(current)
    end
    return session
end
