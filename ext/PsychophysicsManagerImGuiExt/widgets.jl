# Drawing helpers shared by the views. Every string the dashboard shows goes
# through `TextUnformatted`: ImGui's `Text` family reads its argument as a printf
# format, and a participant ID or an error message may hold a `%`.

const RGBA = NTuple{4, Float32}

# The colours come from the logo (`assets/logo.svg`): its slate tile is the ground,
# its pale blue curve the accent, and its Julia red, green and purple points, softened
# to pastels, carry what a colour says. The pastels stay the lightest marks on the
# screen; the fills under text are their dark tints.
const LOGO_TILE = (0.122f0, 0.145f0, 0.192f0, 1.0f0)
const ACCENT = (0.55f0, 0.71f0, 0.93f0, 1.0f0)
const LOGO_POINTS = ((0.835f0, 0.388f0, 0.361f0, 1.0f0),
                     (0.376f0, 0.678f0, 0.318f0, 1.0f0),
                     (0.667f0, 0.475f0, 0.757f0, 1.0f0))
const PASTEL_GREEN = (0.62f0, 0.84f0, 0.60f0, 1.0f0)
const PASTEL_RED = (0.94f0, 0.62f0, 0.60f0, 1.0f0)
const PASTEL_PURPLE = (0.78f0, 0.66f0, 0.87f0, 1.0f0)
const PASTEL_AMBER = (0.94f0, 0.79f0, 0.52f0, 1.0f0)
tint(color::RGBA, alpha::Real) = (color[1], color[2], color[3], Float32(alpha))

const DIM_TEXT = (0.60f0, 0.64f0, 0.71f0, 1.0f0)
const TYPING_TEXT = PASTEL_AMBER
const KEYS_TEXT = PASTEL_GREEN
const PROGRESS = (0.36f0, 0.50f0, 0.70f0, 1.0f0)
# The conditions' means and their error bars; the fitted curve is the accent
const MEANS = PASTEL_PURPLE
# Single trials under the conditions' points: a quiet grey, and a red ring for one
# that no longer counts
const TRIAL_POINTS = (0.78f0, 0.81f0, 0.86f0, 1.0f0)
const SET_ASIDE_POINTS = PASTEL_RED
const EARLIER_LINE = tint(DIM_TEXT, 0.70f0)
const SMOOTH_LINE = PASTEL_AMBER

# A section's bar, faintly tinted by what it holds
const SECTION_BAR = (0.19f0, 0.24f0, 0.33f0, 1.0f0)
const SECTION_BAR_STIMULUS = (0.18f0, 0.28f0, 0.24f0, 1.0f0)
const SECTION_BAR_MESSAGES = (0.27f0, 0.22f0, 0.33f0, 1.0f0)

# An edit field holding a value that was refused
const REFUSED = (0.44f0, 0.19f0, 0.21f0, 1.0f0)
# An edit field holding a value for the preview only
const PREVIEW_FIELD = (0.17f0, 0.19f0, 0.23f0, 1.0f0)

# Button colours by what the action does: start, correct, end
const GO = (0.22f0, 0.42f0, 0.28f0, 1.0f0)
const WARN = (0.47f0, 0.37f0, 0.19f0, 1.0f0)
const DANGER = (0.47f0, 0.21f0, 0.23f0, 1.0f0)

const STATE_COLORS = Dict(
    READY    => (0.78f0, 0.83f0, 0.90f0, 1.0f0),
    RUNNING  => PASTEL_GREEN,
    PAUSED   => PASTEL_AMBER,
    FINISHED => (0.68f0, 0.77f0, 0.90f0, 1.0f0),
    ABORTED  => PASTEL_RED,
)

# The frames, tabs and headers are the logo's slate; the accent marks what the
# operator acts on or reads off: the selection, a check mark, the tab in front. The
# coloured buttons, the state and the data keep their own colours
const WINDOW_GROUND = (0.082f0, 0.094f0, 0.122f0, 1.00f0)
const STYLE_COLORS = (
    (ig.lib.ImGuiCol_WindowBg,           WINDOW_GROUND),
    (ig.lib.ImGuiCol_PopupBg,            (0.10f0, 0.12f0, 0.155f0, 0.98f0)),
    (ig.lib.ImGuiCol_Border,             (0.27f0, 0.31f0, 0.39f0, 0.55f0)),
    (ig.lib.ImGuiCol_FrameBg,            (0.15f0, 0.18f0, 0.23f0, 1.00f0)),
    (ig.lib.ImGuiCol_FrameBgHovered,     (0.20f0, 0.24f0, 0.30f0, 1.00f0)),
    (ig.lib.ImGuiCol_FrameBgActive,      (0.24f0, 0.29f0, 0.36f0, 1.00f0)),
    (ig.lib.ImGuiCol_TitleBg,            LOGO_TILE),
    (ig.lib.ImGuiCol_TitleBgActive,      LOGO_TILE),
    (ig.lib.ImGuiCol_MenuBarBg,          LOGO_TILE),
    (ig.lib.ImGuiCol_Button,             (0.19f0, 0.23f0, 0.30f0, 1.00f0)),
    (ig.lib.ImGuiCol_ButtonHovered,      (0.25f0, 0.30f0, 0.38f0, 1.00f0)),
    (ig.lib.ImGuiCol_ButtonActive,       (0.30f0, 0.36f0, 0.46f0, 1.00f0)),
    (ig.lib.ImGuiCol_Header,             tint(ACCENT, 0.22)),
    (ig.lib.ImGuiCol_HeaderHovered,      (0.23f0, 0.28f0, 0.36f0, 1.00f0)),
    (ig.lib.ImGuiCol_HeaderActive,       (0.28f0, 0.34f0, 0.43f0, 1.00f0)),
    (ig.lib.ImGuiCol_Tab,                (0.12f0, 0.14f0, 0.19f0, 1.00f0)),
    (ig.lib.ImGuiCol_TabHovered,         (0.24f0, 0.29f0, 0.37f0, 1.00f0)),
    (ig.lib.ImGuiCol_TabSelected,        (0.20f0, 0.25f0, 0.33f0, 1.00f0)),
    (ig.lib.ImGuiCol_TabSelectedOverline, ACCENT),
    (ig.lib.ImGuiCol_TabDimmed,          (0.10f0, 0.12f0, 0.15f0, 1.00f0)),
    (ig.lib.ImGuiCol_TabDimmedSelected,  (0.16f0, 0.20f0, 0.26f0, 1.00f0)),
    (ig.lib.ImGuiCol_TabDimmedSelectedOverline, (0.42f0, 0.51f0, 0.64f0, 1.00f0)),
    (ig.lib.ImGuiCol_CheckMark,          ACCENT),
    (ig.lib.ImGuiCol_SliderGrab,         ACCENT),
    (ig.lib.ImGuiCol_Separator,          (0.24f0, 0.28f0, 0.35f0, 1.00f0)),
    (ig.lib.ImGuiCol_SeparatorHovered,   tint(ACCENT, 0.70)),
    (ig.lib.ImGuiCol_SeparatorActive,    ACCENT),
    (ig.lib.ImGuiCol_ResizeGrip,         (0.30f0, 0.35f0, 0.43f0, 0.20f0)),
    (ig.lib.ImGuiCol_ResizeGripHovered,  tint(ACCENT, 0.60)),
    (ig.lib.ImGuiCol_ResizeGripActive,   ACCENT),
    (ig.lib.ImGuiCol_TableHeaderBg,      (0.14f0, 0.17f0, 0.22f0, 1.00f0)),
    (ig.lib.ImGuiCol_TableBorderStrong,  (0.24f0, 0.28f0, 0.35f0, 1.00f0)),
    (ig.lib.ImGuiCol_TableBorderLight,   (0.18f0, 0.21f0, 0.26f0, 1.00f0)),
    (ig.lib.ImGuiCol_TableRowBgAlt,      tint(ACCENT, 0.03)),
    (ig.lib.ImGuiCol_DockingPreview,     tint(ACCENT, 0.50)),
    (ig.lib.ImGuiCol_DockingEmptyBg,     WINDOW_GROUND),
    (ig.lib.ImGuiCol_TextSelectedBg,     tint(ACCENT, 0.35)),
)

function apply_style!()
    ig.StyleColorsDark()
    style = ig.GetStyle()
    colors = Ptr{ig.ImVec4}(style.Colors)
    for (slot, color) in STYLE_COLORS
        unsafe_store!(colors, ig.ImVec4(color...), Int(slot) + 1)
    end
    style.FrameRounding = style.GrabRounding = style.TabRounding = style.PopupRounding = 3f0
    # The View menu opens and closes the views; a tab bar has no menu of its own
    style.WindowMenuButtonPosition = ig.lib.ImGuiDir_None
    return nothing
end

text(s::AbstractString) = ig.TextUnformatted(s)

function colored_text(s::AbstractString, color::RGBA)
    ig.PushStyleColor(ig.lib.ImGuiCol_Text, color)
    ig.TextUnformatted(s)
    ig.PopStyleColor()
    return nothing
end

function wrapped_text(s::AbstractString; color::Union{Nothing, RGBA} = nothing)
    color === nothing || ig.PushStyleColor(ig.lib.ImGuiCol_Text, color)
    ig.PushTextWrapPos(0.0f0)
    ig.TextUnformatted(s)
    ig.PopTextWrapPos()
    color === nothing || ig.PopStyleColor()
    return nothing
end

# Whether the text field drawn last hands its text over as it lets go of the keyboard:
# after an edit, or, while it holds a refused value, unchanged too, since what refused
# it may have been put right elsewhere
submitted(refused::Bool) =
    ig.IsItemDeactivatedAfterEdit() || (refused && ig.IsItemDeactivated())

"A short explanation of the item drawn last, shown while the mouse rests on it, disabled or not."
tooltip(key::Symbol) = tooltip(ui_label(key))

# A text the item drawn last may not show whole, such as a cell's
function tooltip(s::AbstractString)
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 28)
        ig.TextUnformatted(s)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
    return nothing
end

# The heading of a section of a view, a bar across it brighter than the fields under
# it, and whether the section is open: it is until the operator folds it
function section_bar(label::AbstractString; color::RGBA = SECTION_BAR)
    ig.Spacing()
    ig.PushStyleColor(ig.lib.ImGuiCol_Header, color)
    open = ig.CollapsingHeader(label, ig.lib.ImGuiTreeNodeFlags_DefaultOpen)
    ig.PopStyleColor()
    return open
end

"""
    menu_item(key, enabled) -> Bool

A menu item labelled `ui_label(key)` and explained by the tooltip `tip_<key>`,
greyed out while `enabled` is false. Returns whether it was chosen.
"""
function menu_item(key::Symbol, enabled::Bool)
    chosen = ig.MenuItem(ui_label(key), C_NULL, false, enabled)
    tooltip(Symbol("tip_", key))
    return chosen && enabled
end

"""
    button(label, enabled; width = 0, color = nothing) -> Bool

A button that is greyed out and inert while its action is unavailable, so an
operator can see that pressing it would do nothing. Returns whether it was pressed.
"""
function button(label::AbstractString, enabled::Bool; width::Real = 0,
                color::Union{Nothing, RGBA} = nothing)
    ig.BeginDisabled(!enabled)
    if color !== nothing
        lighter = (min(color[1] + 0.08f0, 1f0), min(color[2] + 0.08f0, 1f0),
                   min(color[3] + 0.08f0, 1f0), 1f0)
        ig.PushStyleColor(ig.lib.ImGuiCol_Button, color)
        ig.PushStyleColor(ig.lib.ImGuiCol_ButtonHovered, lighter)
        ig.PushStyleColor(ig.lib.ImGuiCol_ButtonActive, lighter)
    end
    pressed = ig.Button(label, (Float32(width), 0f0))
    color === nothing || ig.PopStyleColor(3)
    ig.EndDisabled()
    return pressed && enabled
end

"A label and its value on one line, the values of a panel aligned in one column."
function field(label::AbstractString, value::AbstractString, label_width::Real;
               color::Union{Nothing, RGBA} = nothing)
    text(label)
    ig.SameLine(Float32(label_width))
    color === nothing ? text(value) : colored_text(value, color)
    return nothing
end

# A NUL-terminated buffer that an ImGui text field edits in place
function text_buffer(initial::AbstractString; size::Int = 1024)
    buffer = zeros(UInt8, size)
    copyto!(buffer, codeunits(initial))
    return buffer
end

buffer_text(buffer::Vector{UInt8}) =
    String(buffer[1:something(findfirst(iszero, buffer), length(buffer) + 1) - 1])

"Replaces what a text field's buffer holds, as when the operator picks from a list."
function fill_buffer!(buffer::Vector{UInt8}, value::AbstractString)
    fill!(buffer, 0x00)
    copyto!(buffer, codeunits(value))
    return buffer
end
