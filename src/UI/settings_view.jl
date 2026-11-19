# What the dashboard's Settings view shows and writes, decided without a window:
# every section a loader reads, with the value in effect, its default and the file it
# came from. Reading, checking and writing the files is `src/IO/settings.jl`'s.

"""
    SettingRow

One line of the Settings view: a key of its section, its `value` in effect as the
operator reads and types it, its `default` as shown, whether a file sets it (`in_file`)
and which (`source`), the rig's value it replaces when a project's file sets a key the
per-user file sets too (`replaces`), the interface text that explains it (`tip`), and
the `choices` of a key that takes one of a list.
"""
Base.@kwdef struct SettingRow
    key::String
    kind::Symbol
    value::String
    default::String
    in_file::Bool
    source::Union{Nothing, String} = nothing
    replaces::Union{Nothing, String} = nothing
    required::Bool
    tip::Symbol
    choices::Vector{String} = String[]
end

"""
    SettingsSectionRows

A section of the Settings view: its name, the file a value no file sets yet is written
to unless the operator chooses another (`target`, [`new_setting_target`](@ref)), and
its lines.
"""
struct SettingsSectionRows
    name::String
    target::String
    rows::Vector{SettingRow}
end

setting_text(::Nothing) = ""
setting_text(value::AbstractString) = String(value)
setting_text(value) = string(value)

function default_text(spec::SettingSpec)
    spec.required && return ui_label(:setting_required)
    spec.default === nothing && return ui_label(:setting_unset)
    spec.default == "" && return ui_label(:setting_empty)
    return setting_text(spec.default)
end

# A combining check is explained by the tooltip Browse gives it, and a constant the
# laboratory named in [rig] by one tooltip for them all
function setting_tip(section::AbstractString, key::AbstractString)
    section == "combining" && return Symbol("tip_check_", key)
    section == "rig" && !any(spec -> spec.key == key, setting_specs("rig")) &&
        return :tip_setting_rig_constant
    return Symbol("tip_setting_", section, "_", key)
end

# The languages the interface has text for
interface_languages() = sort!([first(splitext(file)) for file in readdir(LOCALE_DIRECTORY)
                               if endswith(file, ".toml")])

setting_choices(section::AbstractString, key::AbstractString) =
    (section, key) == ("ui", "language") ? interface_languages() :
    (section, key) == ("display", "presentation_mode") ? collect(string.(PRESENTATION_MODES)) :
    String[]

"""
    dashboard_settings(directory = ".") -> Vector{SettingsSectionRows}

Every section of the settings in effect for `directory`, in the order of
[`settings_schema`](@ref), as the Settings view lists them; `[rig]` also lists the
constants the files name there, after its own keys.
"""
function dashboard_settings(directory::AbstractString = ".")
    user_file = user_settings_file()
    return map(settings_schema()) do (name, specs)
        section = settings_section(name, directory)
        if name == "rig"
            own = Set(spec.key for spec in specs)
            specs = [specs; [rig_constant_spec(key)
                             for key in sort!(collect(keys(section.values))) if !(key in own)]]
        end
        rig_values = something(isfile(user_file) ? file_section(user_file, name) : nothing,
                               Dict{String, Any}())
        rows = map(specs) do spec
            source = get(section.sources, spec.key, nothing)
            replaced = source !== nothing && source != user_file &&
                       haskey(rig_values, spec.key) ? setting_text(rig_values[spec.key]) :
                                                      nothing
            SettingRow(key = spec.key, kind = spec.kind,
                       value = setting_text(setting_in_effect(section, spec.key)),
                       default = setting_default_text(section, spec),
                       in_file = source !== nothing, source = source, replaces = replaced,
                       required = spec.required,
                       tip = setting_tip(name, spec.key),
                       choices = setting_choices(name, spec.key))
        end
        SettingsSectionRows(name, new_setting_target(name, directory), rows)
    end
end

# A pixel's visual angle no file states is derived when the rig gives what it needs
function setting_default_text(section::SettingsSection, spec::SettingSpec)
    if (section.name, spec.key) == ("rig", "pixel_arcmin")
        derived = try
            derived_pixel_arcmin(Dict{String, Any}(
                key => checked_setting("rig", key, section.values[key])
                for key in ("pixel_pitch_mm", "viewing_distance_mm")
                if haskey(section.values, key)))
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
        derived === nothing ||
            return ui_label(:setting_derived; value = string(round(derived; sigdigits = 4)))
    end
    return default_text(spec)
end

# The value the operator typed, as the file stores it: text as typed, a number read
# from the text, a switch from "true" or "false". An empty number is `nothing`, which
# returns the key to its default.
function setting_input(section::AbstractString, key::AbstractString, text::AbstractString)
    spec = setting_spec(section, key)
    spec.kind === :string && return String(text)
    typed = strip(text)
    spec.kind === :bool && return typed == "true" ? true : typed == "false" ? false : typed
    isempty(typed) && return nothing
    number = spec.kind === :integer ? tryparse(Int, typed) : tryparse(Float64, typed)
    # A text that is no number goes on as text, which `checked_setting` refuses with
    # the words of the rule
    return something(number, typed)
end

"""
    unread_settings_text(directory = ".") -> Union{Nothing, String}

What [`unread_settings`](@ref) finds, as the panel says it, or `nothing`.
"""
function unread_settings_text(directory::AbstractString = ".")
    unread = unread_settings(directory)
    isempty(unread) && return nothing
    return ui_label(:msg_settings_unread;
                    names = join(("$name ($path)" for (path, name) in unread), ", "))
end

"""
    edit_dashboard_setting!(controller, section, key, text; target = nothing) -> Bool

Writes the value the operator typed for `key` of `[section]` into the settings file the
section comes from, or, for a section no file defines yet, into `target`, one of
[`settings_targets`](@ref) ([`write_settings!`](@ref)). Text is taken as typed, a
number is read from it, a switch is `"true"` or `"false"`, and an empty number returns
the key to its default. The panel names the file written, or why nothing was written.

The language applies at once; every other setting from its next use — the next
session, window or dataset — and a running session is not touched.
"""
function edit_dashboard_setting!(controller::DashboardController, section::AbstractString,
                                 key::AbstractString, text::AbstractString;
                                 target::Union{Nothing, AbstractString} = nothing)
    return write_dashboard_setting!(controller, section, key,
                                    () -> setting_input(section, key, text), target)
end

"""
    reset_dashboard_setting!(controller, section, key) -> Bool

Returns `key` of `[section]` to its default: the line that sets it in the settings file
is commented out.
"""
reset_dashboard_setting!(controller::DashboardController, section::AbstractString,
                         key::AbstractString) =
    write_dashboard_setting!(controller, section, key, Returns(nothing), nothing)

function write_dashboard_setting!(controller::DashboardController, section::AbstractString,
                                  key::AbstractString, value::Function,
                                  target::Union{Nothing, AbstractString})
    try
        new_value = value()
        path = write_settings!(section, Dict{String, Any}(key => new_value); target)
        section == "ui" && set_ui_language!(nothing)
        if section == "display" && key == "presentation_mode" &&
           controller.presentation_mode_override === nothing &&
           (controller.session === nothing || controller.session.state == READY)
            controller.presentation_mode = settings_presentation_mode()
        end
        set_message!(controller, new_value === nothing ?
                     ui_label(:msg_setting_reset; section, key, path) :
                     ui_label(:msg_setting_saved; section, key, path))
        return true
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_setting_refused; error = err.msg))
        return false
    end
end
