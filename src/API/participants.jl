# The people measured with PsychophysicsManager: one registry
# file in the data directory holding what is known about each of them, and nothing of
# it in the session files, which name a participant and no more.

"""
    participant_registry_path(directory = ".") -> String

The participant registry: `participants.toml` in the data directory the settings
resolve from `directory` ([`resolve_data_dir`](@ref)).
"""
participant_registry_path(directory::AbstractString = ".") =
    joinpath(resolve_data_dir(String(directory)), "participants.toml")

"""
    register_participant!(id, metadata = Dict(); directory = ".") -> Dict{String, Any}

Records what is known about the participant `id` and returns their profile as it now
stands.

The metadata is free-form — whatever the laboratory keeps about a person, in any shape
TOML holds: numbers, strings, booleans, dates, and lists or tables of those.

```julia
register_participant!("P01", Dict("age" => 25, "vision" => "corrected to normal"))
register_participant!("P01", Dict("notes" => "wears glasses for the far display"))
```

A second registration of the same id adds to the profile and replaces the keys it
names, leaving the rest: a participant is described as the laboratory learns about
them. A key holding a table is replaced whole, not merged key by key. The registry
is plain TOML and may be read or edited by hand, but the program rewrites it whole,
so comments written into it are not kept; a key is dropped by editing it out.

Sessions carry the participant's id and nothing else about them, so a
dataset is shared or archived without identifying the people in it, and the session
files are unaffected by whether a registry exists at all.

The reserved id [`DEFAULT_PARTICIPANT_ID`](@ref) is refused: it is the dummy every
rapid setup and equipment test is recorded under, so it stands for no one.
"""
function register_participant!(id::AbstractString,
                               metadata::AbstractDict = Dict{String, Any}();
                               directory::AbstractString = ".")
    isempty(strip(id)) && throw(ArgumentError("A participant needs a non-empty id."))
    id == DEFAULT_PARTICIPANT_ID && throw(ArgumentError(
        "\"$DEFAULT_PARTICIPANT_ID\" is the dummy participant that rapid setups and " *
        "equipment tests are recorded under, so it stands for no one and takes no " *
        "profile. Register the person under their own id."))

    profile = Dict{String, Any}()
    for (key, value) in metadata
        name = string(key)
        try
            TOML.print(devnull, Dict(name => value))
        catch
            throw(ArgumentError(
                "The profile of participant \"$id\" gives `$name` as $(repr(value)), " *
                "which the registry cannot hold; a value is a number, a string, a " *
                "boolean, a date, or a list or table of those."))
        end
        profile[name] = value
    end

    path = participant_registry_path(directory)
    registry = read_participant_registry(path)
    merged = merge(get(registry, String(id), Dict{String, Any}()), profile)
    registry[String(id)] = merged
    write_participant_registry(path, registry)
    return merged
end

"""
    get_participant(id; directory = ".") -> Union{Nothing, Dict{String, Any}}

The profile of the participant `id` ([`register_participant!`](@ref)), or `nothing`
when the registry does not know them — which is also what an unregistered participant
of a saved session gives, since measuring one never requires registering them.
"""
get_participant(id::AbstractString; directory::AbstractString = ".") =
    get(read_participant_registry(participant_registry_path(directory)), String(id),
        nothing)

"""
    list_participants(; directory = ".") -> Vector{String}

The ids in the registry, sorted. Sessions are joined to profiles by this id.
"""
list_participants(; directory::AbstractString = ".") =
    sort!(collect(keys(read_participant_registry(participant_registry_path(directory)))))

# A registry that is not there holds nobody: a laboratory that never registers anyone
# still runs sessions, and reading is not the moment to create the file.
function read_participant_registry(path::AbstractString)
    registry = Dict{String, Dict{String, Any}}()
    isfile(path) || return registry

    parsed = TOML.parsefile(path)
    extra = sort(collect(setdiff(keys(parsed), ["participants"])))
    isempty(extra) || throw(ArgumentError(
        "The participant registry $path has unknown top-level keys " *
        "$(join(extra, ", ")); every participant is a [participants.<id>] table."))
    entries = get(parsed, "participants", Dict{String, Any}())
    entries isa AbstractDict || throw(ArgumentError(
        "The participant registry $path gives `participants` as $(repr(entries)); the " *
        "participants are [participants.<id>] tables."))
    for (id, profile) in entries
        profile isa AbstractDict || throw(ArgumentError(
            "The participant registry $path gives participant \"$id\" as " *
            "$(repr(profile)); a participant is a [participants.<id>] table of what " *
            "is known about them."))
        registry[String(id)] = Dict{String, Any}(string(key) => value
                                                 for (key, value) in profile)
    end
    return registry
end

# Rendered before the file is touched, so that a value TOML cannot hold leaves neither
# a half-written registry nor a temporary file behind
function write_participant_registry(path::AbstractString, registry::AbstractDict)
    rendered = sprint(io -> TOML.print(io, Dict("participants" => registry);
                                       sorted = true))
    return atomic_write(String(path)) do io
        println(io, "# The people measured with PsychophysicsManager, written by the program:")
        println(io, "# it rewrites this file whole, so comments added here are lost.")
        println(io, "# Session files name a participant and hold nothing else about")
        println(io, "# them, so this is the only place a person is described.")
        println(io)
        print(io, rendered)
    end
end
