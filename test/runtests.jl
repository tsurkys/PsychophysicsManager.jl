using Test
using Random
using PsychophysicsManager

# The tests read the interface in English, whatever language the settings.toml
# around them asks for
set_ui_language!("en")

# A temporary directory is named by its real path, as the working directory is after `cd`
# into it: macOS's /var is a link to /private/var, and Windows' TEMP may hold a short
# (8.3) name
let real_tempdir = realpath(tempdir())
    for variable in (Sys.iswindows() ? ("TMP", "TEMP") : ("TMPDIR",))
        ENV[variable] = real_tempdir
    end
end

# The tests never read the developer's own per-user settings, the rig's: they get a file
# of their own, in a temporary directory
const USER_SETTINGS_DIRECTORY = mktempdir()
ENV[PsychophysicsManager.USER_SETTINGS_VARIABLE] =
    joinpath(USER_SETTINGS_DIRECTORY, "settings.toml")

# The test files in the order they run. `extensions` stays last: it loads
# GLMakie/PortAudio, and every file before it asserts a headless session.
const TEST_FILES = ["methods", "marker_layout", "gabor", "audio", "storage", "settings", "export",
                    "analytics", "core", "psi", "messages", "scenario", "participants", "analysis_set",
                    "library", "remote", "observers", "ui", "control", "examples", "extensions"]

# `Pkg.test(test_args = ["core", "storage"])` runs only the files named, and
# `["-extensions"]` all files but the one named.
const EXCLUDED = [chop(arg; head = 1, tail = 0) for arg in ARGS if startswith(arg, "-")]
const NAMED = filter(arg -> !startswith(arg, "-"), ARGS)
const SELECTED = setdiff(isempty(NAMED) ? TEST_FILES : NAMED, EXCLUDED)
let unknown = setdiff(union(NAMED, EXCLUDED), TEST_FILES)
    isempty(unknown) ||
        error("Unknown test file(s) $(join(unknown, ", ")); known: $(join(TEST_FILES, ", "))")
end

# What the data directory of the project the suite runs in holds: a test writes its
# session files into a directory of its own, never there
data_directory_listing() =
    (dir = PsychophysicsManager.resolve_data_dir(); isdir(dir) ? sort(readdir(dir)) : String[])

@testset "PsychophysicsManager" begin
    found = data_directory_listing()
    for name in TEST_FILES
        name in SELECTED && include("test_$name.jl")
    end
    @testset "The suite leaves the data directory as it found it" begin
        @test setdiff(data_directory_listing(), found) == String[]
    end
end
