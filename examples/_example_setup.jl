# Shared setup for the development and laboratory test scripts in this directory.
# Activating a project does not change `pwd()`, while PsychophysicsManager discovers settings
# and its default data directory from `pwd()`. Pin the working directory so every
# script behaves the same regardless of where it was launched.

using Pkg
Pkg.activate(@__DIR__)
using PsychophysicsManager

function wait_for_enter(prompt::String="Press ENTER to continue...")
    if isinteractive()
        println("\n(Interactive session: no need to press ENTER, windows stay open.)")
        return nothing
    end
    println("\n", prompt)
    readline()
    return nothing
end

const EXAMPLE_LAUNCH_DIRECTORY = pwd()
const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))
const EXAMPLE_WORKING_DIRECTORY = abspath(get(
    ENV,
    "PEM_EXAMPLE_WORKDIR",
    PACKAGE_ROOT,
))
const EXAMPLE_DATA_DIRECTORY = joinpath(EXAMPLE_WORKING_DIRECTORY, "data")

mkpath(EXAMPLE_WORKING_DIRECTORY)
cd(EXAMPLE_WORKING_DIRECTORY)

function resolve_example_path(path::AbstractString)
    isabspath(path) && return normpath(path)
    return normpath(joinpath(EXAMPLE_LAUNCH_DIRECTORY, path))
end

function saved_session_files(directory::AbstractString = EXAMPLE_DATA_DIRECTORY)
    isdir(directory) || return String[]
    files = filter(
        path -> endswith(lowercase(path), ".json"),
        readdir(directory; join = true),
    )
    sort!(files; by = mtime, rev = true)
    return files
end

function newest_session_file(directory::AbstractString = EXAMPLE_DATA_DIRECTORY)
    files = saved_session_files(directory)
    return isempty(files) ? nothing : first(files)
end
