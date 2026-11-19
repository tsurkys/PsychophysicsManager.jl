# Networked model-observer backends: they turn a rendered presentation into one
# request to an external model and report its forced choice.
#
# Everything here is transport. The task wording, the retry policy, the response
# coding and the audit trail live in the headless core (`src/Observers/`), so the
# same experiment runs against a simulated observer with no network at all.
#
# Two properties are deliberate and load-bearing for the measurement, and every
# backend in this extension upholds them:
#
#   * every trial is an independent request with no conversation history, so the
#     model cannot see earlier stimuli or its own earlier answers;
#   * the answer is constrained by a JSON schema, so a trial is either a valid
#     forced choice or explicitly missing data — never a hedge parsed into one.

module PsychophysicsManagerModelObserverExt

using PsychophysicsManager
using HTTP
using PNGFiles
using JSON3
using Base64

import PsychophysicsManager: query_observer, describe_backend, model_observer
using PsychophysicsManager: AbstractObserverBackend, ObserverQuestion, ObserverAnswer,
                 require_api_key, DELIBERATION_LEVELS, check_deliberation,
                 refuse_vendor_deliberation

include("encoding.jl")
include("protocol.jl")
include("claude.jl")
include("openrouter.jl")

end # module
