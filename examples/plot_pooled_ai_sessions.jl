# Joint psychometric plot over all saved sessions from one model-observer condition.
# Edit the selection block, then run:
#
#   julia --project=examples examples/plot_pooled_ai_sessions.jl

include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie

# ====================== SESSION SELECTION ======================

PARTICIPANT_ID  = "google_gemini-3.5-flash-lite"
EXPERIMENT_NAME = "OK_AI_Plain"
DELIBERATION    = "high"
REQUIRED_TAGS   = ["condition:plain", "layout:standard"]

# ===============================================================

function matches_selection(session)
    metadata = session.observer_metadata
    return session.state == FINISHED &&
           session.participant_id == PARTICIPANT_ID &&
           session.ex_par.experiment_name == EXPERIMENT_NAME &&
           get(metadata, "deliberation", nothing) == DELIBERATION &&
           all(tag -> tag in session.tags, REQUIRED_TAGS)
end

selected = filter(matches_selection, load_session.(saved_session_files()))
isempty(selected) && error("No sessions match the SESSION SELECTION block.")

# A selected session measured under another condition is left out, with a warning
pooled = AnalysisSet(selected)
display(pooled)

print_psychometric_summary(pooled)
display(plot_psychometric_curve(pooled;
    title = "$(PARTICIPANT_ID): $(length(pooled.sessions)) pooled sessions"))
wait_for_enter()
