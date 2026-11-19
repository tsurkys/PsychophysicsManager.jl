# The operator dashboard on its own: choose an experiment among the templates or
# the previous sessions, the participant, and start. `save_templates.jl` puts the
# example experiments among the templates. The stimulus backend (GLMakie, the
# audio packages) is loaded when a session starts.

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using CImGui, ImPlot, GLFW, ModernGL   # the operator dashboard

dashboard = open_operator_dashboard()
wait(dashboard)
