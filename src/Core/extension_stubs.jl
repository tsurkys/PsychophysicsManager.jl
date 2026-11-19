# Functions implemented by package extensions. The varargs fallbacks below
# give an actionable error when the required backend is not loaded; the
# extensions add the real methods (with specific signatures, so nothing is
# overwritten).

const _MAKIE_HINT = "Load a Makie backend first, e.g. `using GLMakie` (install with `] add GLMakie`)."

plot_psychometric_curve(args...; kwargs...) = error("plot_psychometric_curve requires a plotting backend. " * _MAKIE_HINT)
plot_adjustment_results(args...; kwargs...) = error("plot_adjustment_results requires a plotting backend. " * _MAKIE_HINT)
plot_psychometric_curve!(args...; kwargs...) = error("plot_psychometric_curve! requires a plotting backend. " * _MAKIE_HINT)
plot_adjustment_results!(args...; kwargs...) = error("plot_adjustment_results! requires a plotting backend. " * _MAKIE_HINT)
plot_adaptive_sequence(args...; kwargs...)  = error("plot_adaptive_sequence requires a plotting backend. " * _MAKIE_HINT)
save_summary_plot(args...; kwargs...)       = error("save_summary_plot requires a plotting backend. " * _MAKIE_HINT)
save_adjustment_plot(args...; kwargs...)    = error("save_adjustment_plot requires a plotting backend. " * _MAKIE_HINT)
visualize_results(args...; kwargs...)       = error("visualize_results requires a plotting backend. " * _MAKIE_HINT)

open_operator_dashboard(args...; kwargs...) = error(
    "The operator dashboard requires Dear ImGui: `using CImGui, ImPlot, GLFW, ModernGL` " *
    "(install with `] add CImGui ImPlot GLFW ModernGL`).")

# ── Display backend hook ─────────────────────────────────────────────────────
# Backend-specific window cleanup before showing results plots. The GLMakie
# extension installs a backend that closes the fullscreen stimulus window and
# switches to windowed mode. Dispatch (not method overwrite) keeps this
# precompile-safe.

abstract type DisplayBackend end
struct NoDisplayBackend <: DisplayBackend end

const ACTIVE_DISPLAY_BACKEND = Ref{DisplayBackend}(NoDisplayBackend())

close_all_windows() = close_all_windows(ACTIVE_DISPLAY_BACKEND[])
close_all_windows(::DisplayBackend) = nothing
