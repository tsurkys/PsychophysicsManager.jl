# Rasterization of a marker layout into a pixel buffer. Kept in the
# headless core and generic in the canvas element type, so the exact pixels a
# participant sees can be unit-tested against a small `Bool` matrix — no
# graphics backend, no window. The GLMakie engine passes its own
# `Matrix{RGBf}` and the two colours it renders with.
#
# Canvas convention: `canvas[x, y]`, column-major with x as the first index —
# the layout Makie's `image!` expects. Stimulus coordinates are relative to the
# anchor chosen in `MarkerLayout`; the origin lands on the canvas centre.

"""
    draw_marker!(canvas, center_x, center_y, width, height, value) -> canvas

Fills a `width`×`height` block of `canvas` centred on `(center_x, center_y)`,
where the coordinates are given in the stimulus frame (origin = canvas centre,
as produced by `calculate_marker_layout`). The block is clipped at the canvas
edges; a marker lying entirely outside leaves the canvas untouched.

Odd sizes extend one pixel further in the positive direction, so a marker is
always exactly `width`×`height` pixels before clipping.
"""
function draw_marker!(canvas::AbstractMatrix, center_x::Real, center_y::Real,
                      width::Integer, height::Integer, value)
    canvas_width, canvas_height = size(canvas)

    ix = round(Int, center_x + canvas_width / 2)
    iy = round(Int, center_y + canvas_height / 2)

    x_range = max(1, ix - fld(width, 2)):min(canvas_width, ix + cld(width, 2) - 1)
    y_range = max(1, iy - fld(height, 2)):min(canvas_height, iy + cld(height, 2) - 1)

    if !isempty(x_range) && !isempty(y_range)
        canvas[x_range, y_range] .= value
    end
    return canvas
end

"""
    render_stimulus!(canvas, params::MarkerLayout; on, off) -> canvas

Clears `canvas` to `off` and draws one marker per distractor and per main-sequence
position of the layout described by `params` (see `docs/STIMULI.md`).

`on` and `off` default to `oneunit`/`zero` of the canvas element type, which is
what a `Bool` or `Float32` test canvas wants; the GLMakie engine passes its
`RGBf` colours explicitly. The stimulus parameters are never mutated,
and nothing here touches a display — a caller may render into
any buffer it owns.
"""
function render_stimulus!(canvas::AbstractMatrix, params::MarkerLayout;
                          on = oneunit(eltype(canvas)), off = zero(eltype(canvas)))
    fill!(canvas, off)

    distractors_x, distractors_y, markers_x, markers_y = calculate_marker_layout(params)
    width, height = params.MarkerSize

    for (x, y) in zip(distractors_x, distractors_y)
        draw_marker!(canvas, x, y, width, height, on)
    end
    for (x, y) in zip(markers_x, markers_y)
        draw_marker!(canvas, x, y, width, height, on)
    end

    return canvas
end
