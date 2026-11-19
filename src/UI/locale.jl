# Operator-interface text in the operator's language. The text lives in one TOML file per language under `locales/`, so a
# language is added by translating `locales/en.toml`, with no change to the code.

const LOCALE_DIRECTORY = normpath(joinpath(@__DIR__, "..", "..", "locales"))
const DEFAULT_UI_LANGUAGE = "en"

# Each language's table, read once; the active language, `nothing` until it is
# first needed or after `set_ui_language!(nothing)`
const LOCALE_TABLES = Dict{String, Dict{String, String}}()
const UI_LANGUAGE = Ref{Union{Nothing, String}}(nothing)

function locale_table(language::String)
    return get!(LOCALE_TABLES, language) do
        path = joinpath(LOCALE_DIRECTORY, "$language.toml")
        if !isfile(path)
            @warn "There is no interface text for language \"$language\" " *
                  "($path); English is shown instead."
            return Dict{String, String}()
        end
        table = Dict{String, String}()
        for (key, text) in TOML.parsefile(path)
            text isa String ? (table[key] = text) :
                @warn "Interface text `$key` in $path is not a string; it is left out."
        end
        return table
    end
end

"""
    ui_language() -> String

The language the operator interface speaks: the one given to
[`set_ui_language!`](@ref), otherwise `[ui] language` of the settings
([`load_ui_language`](@ref)), read when the interface first needs it, otherwise English
(`"en"`).
"""
function ui_language()
    UI_LANGUAGE[] === nothing && (UI_LANGUAGE[] = load_ui_language())
    return UI_LANGUAGE[]
end

"""
    set_ui_language!(language) -> Union{Nothing, String}

Makes the operator interface speak `language` (a locale file name such as `"lt"`);
`nothing` returns to the language of the settings. An open dashboard follows at once:
it draws every label anew each frame.
"""
function set_ui_language!(language::Union{Nothing, AbstractString})
    UI_LANGUAGE[] = language === nothing ? nothing : String(language)
    return UI_LANGUAGE[]
end

"""
    ui_label(key::Symbol; values...) -> String

The operator-interface text named `key` in the active language ([`ui_language`](@ref)),
with each placeholder `{name}` replaced by the value given as `name = value`:

```julia
ui_label(:msg_outlier_marked; trial = 7)   # "Trial 7 marked as an outlier."
```

Text a language does not have is shown in English, and a language without a locale
file is shown in English as a whole: a missing translation is never an error.
"""
ui_label(key::Symbol; values...) = label_in(ui_language(), key; values...)

"""
    english_label(key::Symbol; values...) -> String

The interface text named `key` in English, whatever language the dashboard speaks: the
console speaks English.
"""
english_label(key::Symbol; values...) = label_in(DEFAULT_UI_LANGUAGE, key; values...)

function label_in(language::String, key::Symbol; values...)
    name = String(key)
    text = get(locale_table(language), name, nothing)
    text === nothing && (text = get(locale_table(DEFAULT_UI_LANGUAGE), name, name))
    for (placeholder, value) in values
        text = replace(text, "{$placeholder}" => string(value))
    end
    return text
end
