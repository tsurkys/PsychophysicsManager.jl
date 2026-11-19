# 4px Distance Test (3px lines + 1px gap)
# Goal: Two 3px lines with a clear 1px black gap between them.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie

stim_par = MarkerLayout(
    StimConfig = "r t",
    Ref = 4.0,               # 4px distance between left edges (3px line + 1px gap)
    Diff = 0.0,
    Marker = :rect,
    MarkerSize = (3, 300),   # 3px width
    Color = :white,
    Anchor = :first,
)

ex_par = ExperimentParameters(
    "Gap_Test",
    :Ref,
    [4.0],
    1,
)

method = Adjustment(dep_var = :Diff, dep_range = -20:20)
session = SessionContext(
    "Gap_User",
    ex_par,
    stim_par,
    method;
    tags = ["display-test", "pixel-precision"],
)

# --- INITIALIZATION ---
d_config = load_display_config()
d_config.fullscreen = false
d_config.window_size = (800, 600)
d_config.title = "1-Pixel Gap Precision Test"

engine = initialize_engine(default_engine_type(stim_par), stim_par, d_config)

# --- SESSION RUN ---
println("\n=========================================")
println("       1-PIXEL GAP PRECISION TEST       ")

run_experiment!(session, engine)
println("Checkpoint: $(session.save_path)")
