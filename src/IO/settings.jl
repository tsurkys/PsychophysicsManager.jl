# Application configuration: the `settings.toml` files that describe the rig and the
# project (data directory, monitor, audio device, the rig's constants). Session data
# itself is a different concern and lives in `storage.jl` — configuration describes the
# lab, session files describe the experiments run in it.

using TOML

# ── Default filename configuration ───────────────────────────────────────────

const DEFAULT_STORAGE_CONFIG = Dict{String,Any}(
    # {short_id} keeps filenames unique per session: without it, a second
    # session of the same participant + method would generate the same name
    "filename_template"    => "{participant_id}_{method}({indep_vars})_{short_id}",
    "indep_vars_separator" => "&",
    "timestamp_format"     => "yyyy-mm-dd_HH-MM-SS",
)

# ── The files and the levels they stand for ──────────────────────────────────

"""
    USER_SETTINGS_VARIABLE

The environment variable that names the per-user settings file in place of the one in
the user's configuration directory ([`user_settings_file`](@ref)): for tests, and for a
file a laboratory keeps elsewhere.
"""
const USER_SETTINGS_VARIABLE = "PSYCHOPHYSICSMANAGER_SETTINGS"

"""
    user_settings_file() -> String

The per-user `settings.toml`, the rig's: what is true of the computer whatever project
it runs. `PsychophysicsManager/settings.toml` in the user's configuration directory
(`~/.config` or `XDG_CONFIG_HOME` on Linux, `%APPDATA%` on Windows,
`~/Library/Application Support` on macOS), or the file
[`USER_SETTINGS_VARIABLE`](@ref) names. The file need not exist.
"""
function user_settings_file()
    named = get(ENV, USER_SETTINGS_VARIABLE, "")
    isempty(named) || return abspath(named)
    nonempty(variable, fallback) =
        (value = get(ENV, variable, ""); isempty(value) ? fallback : value)
    base = Sys.iswindows() ? nonempty("APPDATA", joinpath(homedir(), "AppData", "Roaming")) :
           Sys.isapple() ? joinpath(homedir(), "Library", "Application Support") :
           nonempty("XDG_CONFIG_HOME", joinpath(homedir(), ".config"))
    return joinpath(base, "PsychophysicsManager", "settings.toml")
end

"""
    RIG_SECTIONS

The sections that describe the rig rather than a project: one that no file has yet is
written to the per-user file ([`new_setting_target`](@ref)). Any key may still be set at
any level.
"""
const RIG_SECTIONS = ("ui", "display", "audio", "input", "rig", "control", "remote")

"""
    settings_files(directory = ".") -> Vector{String}

The `settings.toml` files the settings for `directory` are read from, nearest first:
those from `directory` upward, the project's, then the per-user file
([`user_settings_file`](@ref)), the rig's, when it exists.
"""
function settings_files(directory::AbstractString = ".")
    files = project_settings_files(directory)
    user = user_settings_file()
    isfile(user) && !(user in files) && push!(files, user)
    return files
end

function project_settings_files(directory::AbstractString)
    files = String[]
    # Through the file's own path: `abspath(".")` ends in a separator, and its
    # `dirname` would be the same directory again
    dir = dirname(joinpath(abspath(directory), "settings.toml"))
    while true
        path = joinpath(dir, "settings.toml")
        isfile(path) && push!(files, path)
        parent = dirname(dir)
        parent == dir && return files
        dir = parent
    end
end

"""
    SettingsSection

A section of the settings as the loaders read it for a directory: its `name`, the
`values` the files set in it, each key from the nearest file that sets it, and that
file for each key (`sources`). A key no file sets is in neither; its default applies.
"""
struct SettingsSection
    name::String
    values::Dict{String, Any}
    sources::Dict{String, String}
end

# The section as the files a search from `directory` set it, key by key. A file that is
# not valid TOML is reported and passed by.
function read_settings_section(directory::AbstractString, name::AbstractString)
    section = SettingsSection(String(name), Dict{String, Any}(), Dict{String, String}())
    for path in settings_files(directory)
        table = file_section(path, name)
        table === nothing && continue
        for (key, value) in table
            haskey(section.values, key) && continue
            section.values[key] = value
            section.sources[key] = path
        end
    end
    return section
end

const UNITS_SECTION_PREFIX = "units."

is_units_section(name::AbstractString) =
    startswith(name, UNITS_SECTION_PREFIX) &&
    !isempty(chop(name; head = length(UNITS_SECTION_PREFIX), tail = 0))

units_stimulus_name(name::AbstractString) =
    String(chop(name; head = length(UNITS_SECTION_PREFIX), tail = 0))

function parsed_section(parsed::AbstractDict, name::AbstractString)
    if is_units_section(name)
        units = get(parsed, "units", nothing)
        units isa AbstractDict || return nothing
        table = get(units, units_stimulus_name(name), nothing)
        return table isa AbstractDict ? table : nothing
    end
    table = get(parsed, name, nothing)
    return table isa AbstractDict ? table : nothing
end

function with_section(old::AbstractDict, name::String, values::Dict{String, Any})
    expected = Dict{String, Any}(old)
    if is_units_section(name)
        units = get(expected, "units", nothing)
        units_copy = units isa AbstractDict ? Dict{String, Any}(units) : Dict{String, Any}()
        units_copy[units_stimulus_name(name)] = values
        expected["units"] = units_copy
    else
        expected[name] = values
    end
    return expected
end

function file_section(path::AbstractString, name::AbstractString)
    parsed = try
        TOML.parsefile(path)
    catch err
        @warn "Failed to parse $path" exception = err
        return nothing
    end
    return parsed_section(parsed, name)
end

# ── What each section holds ──────────────────────────────────────────────────

"""
    SettingSpec

One key of a `settings.toml` section, and the rule its loader reads it by: the kind of
value (`:string`, `:integer`, `:real` or `:bool`), the value taken when the key is
absent (`nothing`: unset), whether the section is unusable without it, and what else a
value must satisfy, with `expects` saying so in words. The loaders and the settings
editor check a value through the same spec ([`checked_setting`](@ref)).
"""
Base.@kwdef struct SettingSpec
    key::String
    kind::Symbol
    default::Any = nothing
    required::Bool = false
    accepts::Function = Returns(true)
    expects::String
end

nonblank(value::AbstractString) = !isempty(strip(value))

const PLOT_SPREADS = (:none, :sd, :sem, :ci)
const PLOT_SPLITS = (:pooled, :overlaid, :panels)

"""
    PlotOptions

The `[plot]` options of the dashboard's Data view: whether to draw single trials (`raw`),
condition means (`mean`), error bars (`spread`: `:none`, `:sd`, `:sem`, or `:ci`), a
model-free moving average (`smooth`), the fitted logistic curve (`fit`), values in
declared units (`converted`), and how ticked sessions are arranged (`split`: `:pooled`,
`:overlaid`, or `:panels`).
"""
Base.@kwdef struct PlotOptions
    raw::Bool = true
    mean::Bool = true
    spread::Symbol = :sem
    smooth::Bool = false
    fit::Bool = true
    converted::Bool = true
    split::Symbol = :pooled

    function PlotOptions(raw::Bool, mean::Bool, spread::Symbol, smooth::Bool,
                         fit::Bool, converted::Bool, split::Symbol)
        spread in PLOT_SPREADS || throw(ArgumentError(
            "`spread` cannot be $(repr(spread)); it takes one of " *
            "$(join(repr.(PLOT_SPREADS), ", "))."))
        split in PLOT_SPLITS || throw(ArgumentError(
            "`split` cannot be $(repr(split)); it takes one of " *
            "$(join(repr.(PLOT_SPLITS), ", "))."))
        return new(raw, mean, spread, smooth, fit, converted, split)
    end
end

"""
    settings_schema() -> Vector{Pair{String, Vector{SettingSpec}}}

Every section a loader reads, in the order the settings editor shows them, with the
keys of each.
"""
settings_schema() = [
    "storage" => [
        SettingSpec(key = "data_dir", kind = :string, default = "data", accepts = nonblank,
                    expects = "a directory, absolute or relative to the settings file"),
        SettingSpec(key = "templates_dir", kind = :string, default = "templates",
                    accepts = nonblank,
                    expects = "a directory, absolute or relative to the settings file"),
        SettingSpec(key = "filename_template", kind = :string,
                    default = DEFAULT_STORAGE_CONFIG["filename_template"], accepts = nonblank,
                    expects = "a file name with {tokens}"),
        SettingSpec(key = "indep_vars_separator", kind = :string,
                    default = DEFAULT_STORAGE_CONFIG["indep_vars_separator"],
                    expects = "text"),
        SettingSpec(key = "timestamp_format", kind = :string,
                    default = DEFAULT_STORAGE_CONFIG["timestamp_format"], accepts = nonblank,
                    expects = "a date format such as yyyy-mm-dd_HH-MM-SS"),
    ],
    "ui" => [
        SettingSpec(key = "language", kind = :string, default = DEFAULT_UI_LANGUAGE,
                    accepts = nonblank, expects = "a language name such as \"en\" or \"lt\""),
    ],
    "display" => [
        SettingSpec(key = "screen_idx", kind = :integer, default = 1, accepts = >=(1),
                    expects = "a monitor number from 1"),
        SettingSpec(key = "screen_name", kind = :string, default = "",
                    expects = "a fragment of a monitor's name, or empty"),
        SettingSpec(key = "fullscreen", kind = :bool, default = false,
                    expects = "true or false"),
        SettingSpec(key = "width", kind = :integer, default = 1200, accepts = >=(1),
                    expects = "a width in pixels, at least 1"),
        SettingSpec(key = "height", kind = :integer, default = 800, accepts = >=(1),
                    expects = "a height in pixels, at least 1"),
        SettingSpec(key = "title", kind = :string, default = "PsychophysicsManager Stimulus",
                    expects = "text"),
        SettingSpec(key = "dashboard_screen_idx", kind = :integer, accepts = >=(1),
                    expects = "a monitor number from 1"),
        SettingSpec(key = "dashboard_screen_name", kind = :string, default = "",
                    expects = "a fragment of a monitor's name, or empty"),
    ],
    # Besides these, any key of [rig] names a constant of the rig (`rig_constant_spec`)
    "rig" => [
        SettingSpec(key = "name", kind = :string, default = "", expects = "the rig's name"),
        SettingSpec(key = "pixel_pitch_mm", kind = :real, accepts = >(0),
                    expects = "the width of a pixel in millimetres, greater than 0"),
        SettingSpec(key = "viewing_distance_mm", kind = :real, accepts = >(0),
                    expects = "the distance from the eye to the screen in millimetres, " *
                              "greater than 0"),
        SettingSpec(key = "pixel_arcmin", kind = :real, accepts = >(0),
                    expects = "the visual angle of a pixel in minutes of arc, greater than 0"),
    ],
    "audio" => [
        SettingSpec(key = "output_device", kind = :string, default = "",
                    expects = "an output device's name, or empty for the system's default"),
    ],
    "input" => [
        SettingSpec(key = "min_response_s", kind = :real, default = 0.0, accepts = >=(0),
                    expects = "seconds, 0 or more"),
    ],
    "combining" => [SettingSpec(key = string(check), kind = :bool, default = true,
                                expects = "true or false")
                    for check in COMBINING_CHECKS],
    "plot" => [
        SettingSpec(key = "raw", kind = :bool, default = true, expects = "true or false"),
        SettingSpec(key = "mean", kind = :bool, default = true, expects = "true or false"),
        SettingSpec(key = "spread", kind = :string, default = "sem",
                    accepts = value -> Symbol(value) in PLOT_SPREADS,
                    expects = "one of \"none\", \"sd\", \"sem\", \"ci\""),
        SettingSpec(key = "smooth", kind = :bool, default = false, expects = "true or false"),
        SettingSpec(key = "fit", kind = :bool, default = true, expects = "true or false"),
        SettingSpec(key = "converted", kind = :bool, default = true, expects = "true or false"),
        SettingSpec(key = "split", kind = :string, default = "pooled",
                    accepts = value -> Symbol(value) in PLOT_SPLITS,
                    expects = "one of \"pooled\", \"overlaid\", \"panels\""),
    ],
    "control" => [
        SettingSpec(key = "enabled", kind = :bool, default = false, expects = "true or false"),
        SettingSpec(key = "port", kind = :integer, default = 5556,
                    accepts = port -> 1 <= port <= 65535,
                    expects = "a port number from 1 to 65535"),
    ],
    "remote" => [
        SettingSpec(key = "host", kind = :string, default = "127.0.0.1", accepts = nonblank,
                    expects = "a host name or an IP address"),
        SettingSpec(key = "port", kind = :integer, required = true,
                    accepts = port -> 1 <= port <= 65535,
                    expects = "a port number from 1 to 65535"),
        SettingSpec(key = "read_timeout_s", kind = :real, accepts = >(0),
                    expects = "a number of seconds greater than 0"),
    ],
]

function setting_specs(section::AbstractString)
    is_units_section(section) && return SettingSpec[]
    for (name, specs) in settings_schema()
        name == section && return specs
    end
    throw(ArgumentError("`[$section]` is not a settings section; the sections are " *
                        join(("[$name]" for (name, _) in settings_schema()), ", ") * "."))
end

rig_constant_spec(key::AbstractString) =
    SettingSpec(key = String(key), kind = :real, expects = "a number")

unit_default_spec(key::AbstractString) =
    SettingSpec(key = String(key), kind = :string, expects = "a label or conversion formula")

function setting_spec(section::AbstractString, key::AbstractString)
    is_units_section(section) && return unit_default_spec(key)
    specs = setting_specs(section)
    index = findfirst(spec -> spec.key == key, specs)
    index === nothing && section == "rig" && return rig_constant_spec(key)
    index === nothing && throw(ArgumentError(
        "The [$section] section has no setting `$key`; its settings are " *
        join(("`$(spec.key)`" for spec in specs), ", ") * "."))
    return specs[index]
end

"""
    checked_setting(section, key, value) -> value

`value` as the loader of `[section]` reads `key`: a string as `String`, a whole number
as `Int`, a number as `Float64`. A value the loader refuses throws an `ArgumentError`
saying what the key takes.
"""
function checked_setting(section::AbstractString, key::AbstractString, value)
    spec = setting_spec(section, key)
    kind = spec.kind
    typed = kind === :string ? (value isa AbstractString ? String(value) : nothing) :
            kind === :bool ? (value isa Bool ? value : nothing) :
            value isa Bool ? nothing :
            kind === :integer ? (value isa Integer ? Int(value) : nothing) :
            value isa Real ? Float64(value) : nothing
    (typed !== nothing && spec.accepts(typed)) || throw(ArgumentError(
        "`$key` in [$section] cannot be $(repr(value)); it takes $(spec.expects)."))
    return typed
end

# A key as the files set it, checked; its default when no file sets it
function section_setting(section::SettingsSection, key::String)
    spec = setting_spec(section.name, key)
    if !haskey(section.values, key)
        spec.required && throw(ArgumentError(
            "No settings.toml sets `$key` in the [$(section.name)] section, which needs it: " *
            "$(spec.expects)."))
        return spec.default
    end
    try
        return checked_setting(section.name, key, section.values[key])
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("The settings.toml in $(dirname(section.sources[key])): $(err.msg)"))
    end
end

# ── Loaders ──────────────────────────────────────────────────────────────────
#
# Each reads its section key by key: the nearest file that sets a key gives its value,
# so a project that sets one key leaves the rig's others in force.

"""
    load_storage_config(directory::String=".") -> Dict{String,Any}

The `[storage]` settings for `directory`: each key from the nearest `settings.toml`
that sets it, the built-in defaults for the rest.
"""
function load_storage_config(directory::String=".")
    section = read_settings_section(directory, "storage")
    config = copy(DEFAULT_STORAGE_CONFIG)
    known = Set(spec.key for spec in setting_specs("storage"))
    for (key, value) in section.values
        config[key] = key in known ? section_setting(section, key) : value
    end
    return config
end

"""
    load_display_config(directory::String=".") -> DisplayConfig

The `[display]` settings for `directory`, each key from the nearest `settings.toml`
that sets it.
"""
function load_display_config(directory::String=".")
    section = read_settings_section(directory, "display")
    setting(key) = section_setting(section, key)
    return DisplayConfig(
        screen_idx  = setting("screen_idx"),
        screen_name = setting("screen_name"),
        fullscreen  = setting("fullscreen"),
        window_size = (setting("width"), setting("height")),
        title       = setting("title"),
        dashboard_screen_idx  = setting("dashboard_screen_idx"),
        dashboard_screen_name = setting("dashboard_screen_name"),
    )
end

"""
    load_audio_output_device(directory::String=".") -> Union{Nothing,String}

An optional output-device name, `[audio] output_device` of the settings. An absent or
blank `output_device` means that PortAudio should use the operating system's default
output.
"""
function load_audio_output_device(directory::String=".")
    configured = strip(section_setting(read_settings_section(directory, "audio"),
                                       "output_device"))
    return isempty(configured) ? nothing : String(configured)
end

"""
    resolve_data_dir(directory::String=".") -> String

Directory where session files are written. Taken from the `[storage] data_dir`
setting; a relative value is resolved against the directory of the
`settings.toml` that defined it. Falls back to `"data"` under the current
working directory. The directory is created if missing.
"""
resolve_data_dir(directory::String=".") = resolve_storage_dir(directory, "data_dir")

"""
    resolve_templates_dir(directory::String=".") -> String

Directory of the experiment setups an operator chooses from: templates, session files
with no trials, and scenario plans. Taken from the `[storage] templates_dir` setting
and resolved as [`resolve_data_dir`](@ref) resolves `data_dir`; falls back to
`"templates"` under the current working directory. The directory is created if
missing.
"""
resolve_templates_dir(directory::String=".") = resolve_storage_dir(directory, "templates_dir")

function resolve_storage_dir(directory::String, key::String)
    section = read_settings_section(directory, "storage")
    configured = section_setting(section, key)
    path = haskey(section.sources, key) ?
           (isabspath(configured) ? configured :
                                    joinpath(dirname(section.sources[key]), configured)) :
           joinpath(abspath(directory), configured)
    mkpath(path)
    return path
end

"""
    load_remote_worker_config(directory::String=".") -> NamedTuple

Address of the external presentation worker a [`RemoteEngine`](@ref) connects
to, read from the `[remote]` section of the settings:

```toml
[remote]
host = "127.0.0.1"     # the machine the worker listens on; default 127.0.0.1
port = 5555            # required
read_timeout_s = 60.0  # optional; silence longer than this ends the session
```

The address is configuration and not session data, which is why it lives here
and not in the session file: the same experiment re-run in another laboratory
reaches that laboratory's worker without editing the recorded session.
"""
function load_remote_worker_config(directory::String=".")
    section = read_settings_section(directory, "remote")
    isempty(section.values) && error(
        "No [remote] section was found in a settings.toml at or above " *
        "$(abspath(directory)), nor in the per-user one ($(user_settings_file())). A " *
        "RemoteEngine session needs the address of the worker that owns the display; " *
        "add a [remote] section naming its port.")
    setting(key) = section_setting(section, key)
    return (host = setting("host"), port = setting("port"),
            read_timeout_s = setting("read_timeout_s"))
end

"""
    load_input_config(directory::String=".") -> NamedTuple

The response devices' settings, from the `[input]` section of the settings:
`min_response_s`, the shortest time after a trial's onset at which a key or button
press counts (`0.0`, every press counts, when the section does not set it). A session
takes it when it starts ([`start_session!`](@ref)) and keeps it in its file.

```toml
[input]
min_response_s = 0.3   # a double press or a held key cannot answer the next trial
```
"""
function load_input_config(directory::String=".")
    section = read_settings_section(directory, "input")
    return (min_response_s = Float64(section_setting(section, "min_response_s")),)
end

"""
    load_control_config(directory::String=".") -> NamedTuple

Whether the operator dashboard opens its control channel for scripts and AI agents, and
on which port of the loopback address, from the `[control]` section of the settings
(off, port 5556, when no file gives them):

```toml
[control]
enabled = true
port = 5556
```
"""
function load_control_config(directory::String=".")
    section = read_settings_section(directory, "control")
    return (enabled = section_setting(section, "enabled"),
            port = section_setting(section, "port"))
end

"""
    load_combining_checks(directory::String=".") -> Vector{Symbol}

The optional checks an [`AnalysisSet`](@ref) combines sessions under, read from the
`[combining]` section of the settings. Every check in [`COMBINING_CHECKS`](@ref) is on
unless a file switches it off:

```toml
[combining]
instructions = false   # combine sessions whose task was worded differently
```

A key that names no check, or a value other than `true` or `false`, is refused.
"""
function load_combining_checks(directory::String=".")
    section = read_settings_section(directory, "combining")
    for (key, source) in section.sources
        Symbol(key) in COMBINING_CHECKS || throw(ArgumentError(
            "The [combining] section of the settings.toml in $(dirname(source)) names " *
            "`$key`, which is not a check; the checks are $(join(COMBINING_CHECKS, ", "))."))
    end
    return [check for check in COMBINING_CHECKS if section_setting(section, string(check))]
end

"""
    load_ui_language(directory::String=".") -> String

The language of the operator interface: `[ui] language` of the settings, `"en"` when no
file gives one. A value that is not a language name is
reported and English is used, since a translation never stops a session.
"""
function load_ui_language(directory::String=".")
    section = read_settings_section(directory, "ui")
    try
        return String(strip(section_setting(section, "language")))
    catch err
        err isa ArgumentError || rethrow()
        @warn "$(err.msg) English is used."
        return DEFAULT_UI_LANGUAGE
    end
end

"""
    load_rig(directory::String=".") -> Dict{String, Any}

The rig's constants, from the `[rig]` section of the settings: its `name` and the
numbers the laboratory names there (`pixel_arcmin`, `frame_ms`, …), each key from the
nearest file that sets it. `pixel_arcmin`, the visual angle of one pixel at the centre
of the screen, is derived from `pixel_pitch_mm` and `viewing_distance_mm` when no file
states it. Only what is set or derived is returned. A session records the table when it
starts ([`start_session!`](@ref)), and keeps it when continued elsewhere.

```toml
[rig]
name = "Booth 2"
pixel_pitch_mm = 0.2715
viewing_distance_mm = 1000
frame_ms = 16.667
```
"""
function load_rig(directory::String=".")
    section = read_settings_section(directory, "rig")
    rig = Dict{String, Any}(key => section_setting(section, key) for key in keys(section.values))
    derived = derived_pixel_arcmin(rig)
    derived === nothing || haskey(rig, "pixel_arcmin") || (rig["pixel_arcmin"] = derived)
    return rig
end

# The visual angle one pixel at the centre of the screen subtends, in minutes of arc
derived_pixel_arcmin(rig::AbstractDict) =
    haskey(rig, "pixel_pitch_mm") && haskey(rig, "viewing_distance_mm") ?
    60 * rad2deg(2 * atan(rig["pixel_pitch_mm"] / (2 * rig["viewing_distance_mm"]))) :
    nothing

"""
    load_unit_defaults(stimulus::AbstractString, directory = ".")
        -> Dict{Symbol, NamedTuple{(:text, :source), Tuple{String, String}}}

The `[units.<stimulus>]` unit and label defaults in effect for `directory`, each
parameter from the nearest `settings.toml` that sets it, paired with that file. A value
that is not a string is refused.
"""
function load_unit_defaults(stimulus::AbstractString, directory::AbstractString = ".")
    section = read_settings_section(directory, UNITS_SECTION_PREFIX * stimulus)
    return Dict{Symbol, NamedTuple{(:text, :source), Tuple{String, String}}}(
        Symbol(key) => (text = section_setting(section, key), source = section.sources[key])
        for key in keys(section.values))
end

"""
    load_plot_options(directory = ".") -> PlotOptions

The `[plot]` options in effect for `directory`, each key from the nearest `settings.toml`
that sets it, with built-in defaults for the rest. Refuses invalid values.
"""
function load_plot_options(directory::AbstractString = ".")
    section = read_settings_section(directory, "plot")
    setting(key) = section_setting(section, key)
    return PlotOptions(
        raw = setting("raw"),
        mean = setting("mean"),
        spread = Symbol(setting("spread")),
        smooth = setting("smooth"),
        fit = setting("fit"),
        converted = setting("converted"),
        split = Symbol(setting("split")),
    )
end

"""
    set_plot_option!(key, value; directory = ".") -> String

Writes one `[plot]` option via [`write_settings!`](@ref) into the nearest `settings.toml`
that has a `[plot]` section, or into the per-user file ([`user_settings_file`](@ref))
when none has. Returns the path written.
"""
function set_plot_option!(key::Union{Symbol, AbstractString}, value;
                          directory::AbstractString = ".")
    raw_value = value isa Symbol ? String(value) : value
    has_section = any(path -> file_section(path, "plot") !== nothing,
                      settings_files(directory))
    target = has_section ? nothing : user_settings_file()
    return write_settings!("plot", Dict{String, Any}(String(key) => raw_value);
                           directory, target)
end

# ── Editing ──────────────────────────────────────────────────────────────────
#
# The files are written by hand and carry comments, which TOML.jl does not keep: a
# section is edited as text, line by line, and the edited text is parsed back and
# compared with what the edit should give before anything is written.

"""
    unread_settings(directory = ".") -> Vector{Pair{String, String}}

What the `settings.toml` files a search from `directory` passes write that no setting
reads — a misspelt key or section — as `file => "[section] key"`, `file => "[section]"`
or `file => "key"`.
"""
function unread_settings(directory::AbstractString = ".")
    schema = Dict(settings_schema())
    unread = Pair{String, String}[]
    for path in settings_files(directory)
        parsed = try
            TOML.parsefile(path)
        catch
            continue   # reading the section reports the file
        end
        for (name, value) in parsed
            if !(value isa AbstractDict)
                push!(unread, path => name)
            elseif name == "units"
                for (stim, table) in value
                    if !(table isa AbstractDict)
                        push!(unread, path => "[units] $stim")
                    else
                        header = "[units.$(toml_key(stim))]"
                        for (key, entry) in table
                            entry isa AbstractString ||
                                push!(unread, path => "$header $key")
                        end
                    end
                end
            elseif !haskey(schema, name)
                push!(unread, path => "[$name]")
            elseif name != "rig"   # every key of [rig] names a constant
                known = Set(spec.key for spec in schema[name])
                append!(unread, [path => "[$name] $key" for key in keys(value)
                                 if !(key in known)])
            end
        end
    end
    return sort!(unread)
end

"""
    settings_section(name, directory = ".") -> SettingsSection

The `[name]` section in effect for `directory`, key by key, as its loader reads it.
"""
function settings_section(name::AbstractString, directory::AbstractString = ".")
    setting_specs(name)
    return read_settings_section(directory, name)
end

"""
    setting_in_effect(section::SettingsSection, key) -> value

The value a loader takes for `key`: the file's, otherwise the default (`nothing` for a
key that is unset). A value the loader would refuse is returned as written.
"""
setting_in_effect(section::SettingsSection, key::AbstractString) =
    get(section.values, key, setting_spec(section.name, key).default)

"""
    settings_targets(directory = ".") -> Vector{String}

The files a key no file sets yet may be written to, so that its loader reads it from
`directory`: the project's `settings.toml` files from there upward, nearest first, one
in `directory` itself when it has none, and the per-user file
([`user_settings_file`](@ref)), whether or not they exist yet.
"""
function settings_targets(directory::AbstractString = ".")
    files = project_settings_files(directory)
    for path in (joinpath(abspath(directory), "settings.toml"), user_settings_file())
        path in files || push!(files, path)
    end
    return files
end

"""
    new_setting_target(name, directory = ".") -> String

The file a key of `[name]` that no file sets is written to unless another is chosen:
the nearest file that sets another key of the section, so that a section stays
together; for a section no file has, the per-user file for a section of the rig
([`RIG_SECTIONS`](@ref)) and the project's nearest file otherwise.
"""
function new_setting_target(name::AbstractString, directory::AbstractString = ".")
    for path in settings_files(directory)
        file_section(path, name) === nothing || return path
    end
    return name in RIG_SECTIONS ? user_settings_file() : first(settings_targets(directory))
end

"""
    write_settings!(name, changes; directory = ".", target = nothing) -> String

Writes `changes` (key => value; `nothing` returns a key to its default) into the
`[name]` settings in effect for `directory`, and returns the file written.

A key is written into the file that sets it; a key no file sets goes to `target`, one
of [`settings_targets`](@ref), or by default to [`new_setting_target`](@ref). Changes
that belong in different files are refused, to be made in a call per file. Every value
is checked by the rule its loader applies ([`checked_setting`](@ref)), and a key the
section cannot do without must remain set in some file, so a refused change throws an
`ArgumentError` and writes nothing. A key returned to its default in one file takes the
value a farther file sets, if one does. The rest of the file — comments, order, the
other keys and sections — is kept: a key is replaced on its own line, a key the section
lacks takes the place of a line that comments it out or goes after the section's last
key, a key returned to its default is commented out, and a missing section is added at
the end. The file is written atomically. A file whose text cannot be edited this way —
not valid TOML, or a value spanning several lines — is refused with the advice to edit
it by hand.
"""
function write_settings!(name::AbstractString, changes::AbstractDict;
                         directory::AbstractString = ".",
                         target::Union{Nothing, AbstractString} = nothing)
    name = String(name)
    specs = setting_specs(name)
    checked = Dict{String, Any}(
        String(key) => value === nothing ? nothing : checked_setting(name, String(key), value)
        for (key, value) in changes)
    # Which file sets a key is known only when every file can be read
    for path in settings_files(directory)
        try
            TOML.parsefile(path)
        catch err
            throw(ArgumentError("$path is not valid TOML, so no setting is changed; " *
                                "correct it by hand. $(sprint(showerror, err))"))
        end
    end
    section = read_settings_section(directory, name)
    chosen = target === nothing ? nothing : abspath(target)
    if chosen !== nothing
        candidates = settings_targets(directory)
        chosen in candidates || throw(ArgumentError(
            "A [$name] setting written to $chosen would not be read from " *
            "$(abspath(directory)); it goes to one of $(join(candidates, ", "))."))
    end
    for_new_keys = something(chosen, new_setting_target(name, directory))
    files = String[]
    for (key, value) in checked
        source = get(section.sources, key, nothing)
        if source !== nothing
            chosen === nothing || chosen == source || throw(ArgumentError(
                "`$key` of [$name] is set in $source, so it is changed there."))
            push!(files, source)
        elseif value !== nothing
            push!(files, for_new_keys)
        end
    end
    unique!(files)
    length(files) > 1 && throw(ArgumentError(
        "The changes to [$name] belong in different files ($(join(files, ", "))); " *
        "change the keys of each file in a call of its own."))
    path = isempty(files) ? for_new_keys : only(files)

    old_text = isfile(path) ? read(path, String) : ""
    old = try
        TOML.parse(old_text)
    catch err
        throw(ArgumentError("$path is not valid TOML, so it is not edited; correct it by " *
                            "hand. $(sprint(showerror, err))"))
    end
    # A key no file sets, returned to its default, changes nothing
    order = [spec.key for spec in specs]
    edits = Pair{String, Any}[key => checked[key] for key in sort!(collect(keys(checked));
                                  by = key -> (something(findfirst(==(key), order),
                                                         length(order) + 1), key))
                              if haskey(section.sources, key) || checked[key] !== nothing]
    existing = parsed_section(old, name)
    has_old = existing !== nothing
    values = Dict{String, Any}(something(existing, Dict{String, Any}()))
    for (key, value) in edits
        value === nothing ? delete!(values, key) : (values[key] = value)
    end
    others = [table for table in (file_section(file, name) for file in settings_files(directory)
                                  if file != path)
              if table !== nothing]
    # A section that no file defines and that gains no key stays absent
    remains = has_old || !isempty(values) || !isempty(others)
    for spec in specs
        remains && spec.required && !haskey(values, spec.key) &&
            !any(table -> haskey(table, spec.key), others) && throw(ArgumentError(
                "The [$name] section cannot do without `$(spec.key)`: $(spec.expects)."))
    end

    new_text = edit_settings_text(old_text, name, edits)
    # A key returned to its default in a section no file defines leaves the file as it was
    expected = (has_old || !isempty(values)) ? with_section(old, name, values) : copy(old)
    parsed = try
        TOML.parse(new_text)
    catch
        nothing
    end
    parsed == expected || throw(ArgumentError(
        "The [$name] section of $path cannot be edited without changing more than the " *
        "keys edited (a value spanning several lines, or a key written in another way); " *
        "edit the file by hand."))
    new_text == old_text && return path
    mkpath(dirname(path))   # the per-user file's directory, written the first time
    atomic_write(io -> write(io, new_text), path)
    return path
end

const TABLE_HEADER = r"^\s*\["
const BARE_TOML_KEY = r"^[A-Za-z0-9_-]+$"

escape_regex(s::AbstractString) =
    replace(String(s), r"([\\^$.|?*+()\[\]{}])" => s"\\\1")

toml_key(key::AbstractString) =
    occursin(BARE_TOML_KEY, key) ? String(key) : toml_value(String(key))

function toml_key_regex(key::AbstractString)
    forms = String[escape_regex(toml_value(key))]
    occursin(BARE_TOML_KEY, key) && pushfirst!(forms, escape_regex(key))
    occursin('\'', key) || push!(forms, escape_regex("'$key'"))
    return "(?:" * join(forms, "|") * ")"
end

function section_header_text(name::String)
    is_units_section(name) && return "[units.$(toml_key(units_stimulus_name(name)))]"
    return "[$name]"
end

function section_header(name::String)
    if is_units_section(name)
        stim = units_stimulus_name(name)
        return Regex("^\\s*\\[\\s*" * toml_key_regex("units") * "\\s*\\.\\s*" *
                     toml_key_regex(stim) * "\\s*\\]\\s*(#.*)?\$")
    end
    return Regex("^\\s*\\[\\s*" * toml_key_regex(name) * "\\s*\\]\\s*(#.*)?\$")
end

key_line(key::String) = Regex("^\\s*" * toml_key_regex(key) * "\\s*=")
commented_key_line(key::String) = Regex("^\\s*#\\s*" * toml_key_regex(key) * "\\s*=")
is_assignment(line::AbstractString) = !isempty(strip(line)) && !startswith(lstrip(line), "#")

# The text of a TOML value, as one line of a file
toml_value(value) =
    String(strip(split(sprint(TOML.print, Dict("value" => value)), "="; limit = 2)[2]))

# Where the comment closing an assignment line begins (the spaces before it
# included), or `nothing`: the first `#` outside a string
function trailing_comment_start(line::AbstractString)
    quote_char = nothing
    escaped = false
    equals = findfirst('=', line)
    for index in eachindex(line)
        index <= equals && continue
        char = line[index]
        if quote_char === nothing
            char in ('"', '\'') && (quote_char = char)
            if char == '#'
                start = index
                while start > firstindex(line) && line[prevind(line, start)] in (' ', '\t')
                    start = prevind(line, start)
                end
                return start
            end
        elseif escaped
            escaped = false
        elseif char == '\\' && quote_char == '"'
            escaped = true
        elseif char == quote_char
            quote_char = nothing
        end
    end
    return nothing
end

# `text` with the keys of section `name` set (or, for `nothing`, commented out),
# everything else as it was
function edit_settings_text(text::String, name::String, edits::Vector{Pair{String, Any}})
    newline = occursin("\r\n", text) ? "\r\n" : "\n"
    lines = String.(split(text, r"\r?\n"))
    header = findfirst(line -> occursin(section_header(name), line), lines)
    if header === nothing
        written = ["$(toml_key(key)) = $(toml_value(value))" for (key, value) in edits
                   if value !== nothing]
        isempty(written) && return text
        isempty(lines[end]) && pop!(lines)
        isempty(lines) || push!(lines, "")
        append!(lines, [section_header_text(name); written; ""])
        return join(lines, newline)
    end
    for (key, value) in edits
        stop = something(findnext(line -> occursin(TABLE_HEADER, line), lines, header + 1),
                         length(lines) + 1) - 1
        body = header+1:stop
        active = findfirst(i -> occursin(key_line(key), lines[i]), body)
        if value === nothing
            active === nothing || (lines[body[active]] = "# " * lines[body[active]])
            continue
        end
        assignment = "$(toml_key(key)) = $(toml_value(value))"
        if active !== nothing
            line = lines[body[active]]
            indent = match(r"^\s*", line).match
            comment = trailing_comment_start(line)
            lines[body[active]] = indent * assignment *
                                  (comment === nothing ? "" : line[comment:end])
            continue
        end
        commented = findfirst(i -> occursin(commented_key_line(key), lines[i]), body)
        if commented !== nothing
            lines[body[commented]] = assignment
        else
            last = findlast(i -> is_assignment(lines[i]), body)
            insert!(lines, last === nothing ? header + 1 : body[last] + 1, assignment)
        end
    end
    return join(lines, newline)
end
