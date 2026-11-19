"""
    MarkerLayout

A parametric layout of markers along an axis. The `StimConfig` grammar composes reference and test
segments, gaps, and filler ("distractor") runs, which tilt, mirroring, and
anchoring turn into concrete positions — enough for filled-space (Oppel-Kundt)
figures, Müller-Lyer variants, and plain length comparisons.

The layout itself is a sequence of positions along an axis and carries no
modality of its own; the fields under "Visual" describe how the current visual
engine draws it.
"""
Base.@kwdef mutable struct MarkerLayout <: AbstractStimulusParameters
    # Layout parameters
    StimConfig::String = "r g t"
    Ref::Float64 = 10.0
    Diff::Float64 = 0.0        # test segment ("t") length is derived: Ref + Diff * DiffInvert
    DiffInvert::Float64 = 1.0
    GapHor::Float64 = 0.0
    DShiftVert::Float64 = 0.0
    DShiftHor::Float64 = 0.0
    Angle::Float64 = 0.0
    DistrN::Int = 0
    Step::Float64 = 0.0
    DLength::Float64 = 0.0
    DMirrorHor::Float64 = 0.0
    DMirrorVert::Float64 = 0.0
    StimMirror::Bool = false   # reverse the layout axis (left↔right); see below
    StimVert::Bool = false
    
    # Visual parameters (how the layout is drawn)
    Marker::Symbol = :rect
    MarkerSize::Tuple{Int, Int} = (2, 30)
    Color::Symbol = :white
    Anchor::Symbol = :first        # :first (original), :center, :middle, :last
    
    # Timing
    duration_ms::Float64 = 0.0
end

"The `StimConfig` vocabulary: reference, test, gap, and a distractor run in either direction."
const MARKER_LAYOUT_TOKENS = ("r", "t", "g", "d", "-d")

"Positions the layout can be anchored to (see `docs/STIMULI.md`)."
const MARKER_ANCHORS = (:first, :center, :middle, :last)

"Marker shapes the drawing parameters may name; `:circle` still renders as a rectangle."
const MARKER_SHAPES = (:rect, :circle)

"""
    validate_marker_layout(p::MarkerLayout) -> p

Rejects a layout that cannot mean what it says. Every check here guards a value
the layout would otherwise accept *silently*: an unknown `StimConfig` token is
skipped, so `"d r T"` measures a figure with no test segment, and an unknown
`Anchor` falls back to the origin, so a misspelt one shifts the whole figure.
Both produce a plausible picture of the wrong stimulus, which no later stage can
detect.

Called from [`calculate_marker_layout`](@ref), the entry point every consumer —
the rasterizer, the on-screen engine, the simulated observer — passes through.
"""
# The test segment is `Ref + Diff * DiffInvert` long, so the two are equal at Diff = 0
physical_equality(::MarkerLayout, field::Symbol, ::NamedTuple) =
    field === :Diff ? 0.0 : nothing

function validate_marker_layout(p::MarkerLayout)
    p.Ref >= 0 || throw(ArgumentError("Ref must not be negative, got $(p.Ref)."))
    p.DistrN >= 0 || throw(ArgumentError("DistrN must not be negative, got $(p.DistrN)."))
    all(>(0), p.MarkerSize) ||
        throw(ArgumentError("MarkerSize must be positive in both dimensions, got $(p.MarkerSize)."))
    p.Anchor in MARKER_ANCHORS ||
        throw(ArgumentError("Unknown Anchor $(repr(p.Anchor)); use one of $(MARKER_ANCHORS)."))
    p.Marker in MARKER_SHAPES ||
        throw(ArgumentError("Unknown Marker $(repr(p.Marker)); use one of $(MARKER_SHAPES)."))
    for token in split(p.StimConfig)
        token in MARKER_LAYOUT_TOKENS ||
            throw(ArgumentError("Unknown StimConfig token $(repr(String(token))) in " *
                                "$(repr(p.StimConfig)); the grammar is $(MARKER_LAYOUT_TOKENS)."))
    end
    return p
end

validate_stimulus(p::MarkerLayout) = validate_marker_layout(p)

"""
    calculate_marker_layout(p::MarkerLayout) -> (sx, sy, px, py)

Distractor positions (`sx`, `sy`) and main-sequence positions (`px`, `py`) in
the stimulus frame, relative to the configured `Anchor`.

`StimMirror` reverses the layout axis, so `"d r t"` mirrored draws the same
figure with left and right exchanged. The main sequence keeps its order under
the mirror: segment 2 is the same segment either way.

Pure function: the stimulus parameters are never mutated (presentation must not
change method-relevant parameters).
"""
function calculate_marker_layout(p::MarkerLayout)
    validate_marker_layout(p)

    # --- 0. Pre-calculation ---
    test_len = p.Ref + p.Diff * p.DiffInvert
    actual_step = p.Step == 0.0 && p.DistrN > 0 ? p.Ref / (p.DistrN + 1.0) : p.Step
    
    # --- 1. Distractor base calculation ---
    dx = collect(1.0:Float64(p.DistrN)) .* actual_step
    p.DLength > 0 && (dx = [0.0; dx])
    
    dy = sin(p.Angle * pi / 360.0) .* dx .+ p.DShiftVert
    dx = cos(p.Angle * pi / 360.0) .* dx .+ p.DShiftHor
    
    if p.DMirrorHor != 0
        dx_orig = copy(dx)
        dx = [dx; -p.DMirrorHor .* dx_orig]
        dy = [dy; dy]
    end
    
    # --- 2. Parse StimConfig ---
    px = [0.0]
    sx, sy = Float64[], Float64[]
    tokens = split(p.StimConfig)
    
    for token in tokens
        if token == "d"
            append!(sx, px[end] .+ dx); append!(sy, dy)
        elseif token == "-d"
            append!(sx, px[end] .- dx); append!(sy, dy)
        elseif token == "r"
            push!(px, px[end] + p.Ref)
        elseif token == "t"
            push!(px, px[end] + test_len)
        elseif token == "g"
            push!(px, px[end] + p.GapHor)
        end
    end
    
    # --- 3. Vertical Mirroring ---
    if p.DMirrorVert != 0
        sy_orig, sx_orig = copy(sy), copy(sx)
        append!(sy, -sy_orig .* p.DMirrorVert)
        append!(sx, sx_orig .* p.DMirrorVert)
    end
    
    py = zeros(length(px))
    
    # --- 3b. Horizontal Mirroring Of The Whole Figure ---
    # Reverses the layout axis: the segments `StimConfig` lists left to right are
    # drawn right to left. It is the left/right counterbalancing control every
    # asymmetric figure needs — a genuine percept survives the mirror, a constant
    # side preference does not — and it is a property of the stimulus, not of who
    # is looking at it.
    #
    # The main sequence keeps its order, so segment 2 names the same segment
    # mirrored or not. A response coding tied to the *segment* therefore stays
    # valid while the side it appears on flips; only wording that names a side
    # ("left"/"right") has to follow the mirror.
    if p.StimMirror
        px = -px
        sx = -sx
    end

    # --- 4. Vertical Stimulus Rotation ---
    if p.StimVert
        s_old_x, p_old_x = copy(sx), copy(px)
        sx, sy = sy, -s_old_x .- 30.0
        px, py = py, -p_old_x .- 30.0
    end
    
    # --- 5. Centering/Anchoring (Improved) ---
    all_x = [px; sx]
    if !isempty(all_x)
        if p.Anchor == :center
            offset_x = (minimum(all_x) + maximum(all_x)) / 2.0
            offset_y = (minimum([py; sy]) + maximum([py; sy])) / 2.0
        elseif p.Anchor == :middle && !isempty(px)
            # Pick the middle element of the main sequence (e.g., 2nd of 3)
            mid_idx = div(length(px) + 1, 2)
            offset_x = px[mid_idx]
            offset_y = py[mid_idx]
        elseif p.Anchor == :first
            offset_x = px[1]
            offset_y = py[1]
        elseif p.Anchor == :last
            offset_x = px[end]
            offset_y = py[end]
        else
            offset_x = 0.0
            offset_y = 0.0
        end
        px .-= offset_x
        sx .-= offset_x
        py .-= offset_y
        sy .-= offset_y
    end
    
    return (sx, sy, px, py)
end
