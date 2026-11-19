using Test
using Random
using PsychophysicsManager

# ── Fixtures for message testing ─────────────────────────────────────────────

mutable struct MessageRecordingEngine <: AbstractStimulusEngine
    session::Union{Nothing, SessionContext}
    log::Vector{Tuple{Symbol, String, Bool, Float64, Int}}
    poll_dismissible::Bool

    MessageRecordingEngine(; poll_dismissible = false) =
        new(nothing, Tuple{Symbol, String, Bool, Float64, Int}[], poll_dismissible)
end

function PsychophysicsManager.present_stimulus(::MessageRecordingEngine, ::AbstractStimulusParameters,
                                              ::AbstractVector{<:Number})
    return 1
end

function PsychophysicsManager.present_message(engine::MessageRecordingEngine,
                                              message::ParticipantMessage)
    n_recorded = engine.session === nothing ? 0 : length(engine.session.history)
    push!(engine.log, (message.kind, message.text, message.dismissible, message.min_s, n_recorded))
    if !message.dismissible || engine.poll_dismissible
        while message.keep_waiting()
            sleep(0.01)
        end
    end
    return nothing
end

struct RenderOnlyMsgEngine <: AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::RenderOnlyMsgEngine, ::AbstractStimulusParameters,
                                      ::AbstractVector{<:Number}) = nothing

mutable struct AdjustmentRecordingEngine <: AbstractStimulusEngine
    session::Union{Nothing, SessionContext}
    log::Vector{Tuple{Symbol, String, Bool, Float64, Int}}
    AdjustmentRecordingEngine() = new(nothing, Tuple{Symbol, String, Bool, Float64, Int}[])
end
PsychophysicsManager.present_stimulus(::AdjustmentRecordingEngine, ::AbstractStimulusParameters,
                                      ::AbstractVector{<:Number}) = nothing
function PsychophysicsManager.present_message(engine::AdjustmentRecordingEngine,
                                              message::ParticipantMessage)
    n_recorded = engine.session === nothing ? 0 : length(engine.session.history)
    push!(engine.log, (message.kind, message.text, message.dismissible, message.min_s, n_recorded))
    return nothing
end

struct RecordingMsgSource <: AbstractResponseSource
    inner::ScriptedResponseSource
    log::Vector{Tuple{Symbol, String, Bool, Float64}}
end
RecordingMsgSource(responses) = RecordingMsgSource(ScriptedResponseSource(responses),
                                                   Tuple{Symbol, String, Bool, Float64}[])
PsychophysicsManager.request_response(s::RecordingMsgSource, ctx::TrialContext) =
    request_response(s.inner, ctx)
PsychophysicsManager.request_response(s::RecordingMsgSource) =
    request_response(s.inner)
PsychophysicsManager.present_message(s::RecordingMsgSource, msg::ParticipantMessage) =
    push!(s.log, (msg.kind, msg.text, msg.dismissible, msg.min_s))

# ── Test Suite ───────────────────────────────────────────────────────────────

@testset "Participant Messages" begin
    mktempdir() do dir
        cd(dir) do
            write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

            @testset "1. Recording engine receives instructions, breaks, and closing message" begin
                ex_par = ExperimentParameters("CS6", :duration_ms, [100.0, 200.0, 300.0], 2)
                session = SessionContext("P01", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_task!(session, length_comparison_task())
                set_messages!(session; instructions = true, break_every = 2,
                              break_text = "Take a break", closing_text = "Thanks")

                engine = MessageRecordingEngine()
                engine.session = session

                run_experiment!(session, engine; report = :silent)

                @test session.state == FINISHED
                @test length(session.history) == 6
                # Log contains: instructions (0 trials), break after 2, break after 4, closing after 6 (no break after 6)
                @test length(engine.log) == 4
                @test engine.log[1] == (:instructions, session.task.instructions, true, 0.0, 0)
                @test engine.log[2] == (:break, "Take a break", true, 0.0, 2)
                @test engine.log[3] == (:break, "Take a break", true, 0.0, 4)
                @test engine.log[4] == (:closing, "Thanks", true, 0.0, 6)
                @test all(e[3] for e in engine.log)  # all dismissible
            end

            @testset "2. break_after gives breaks at specified trial counts only" begin
                ex_par = ExperimentParameters("CS4", :duration_ms, [100.0, 200.0], 2)
                session = SessionContext("P02", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session; break_after = [1, 3], break_text = "Rest")

                engine = MessageRecordingEngine()
                engine.session = session

                run_experiment!(session, engine; report = :silent)

                @test session.state == FINISHED
                @test length(session.history) == 4
                @test length(engine.log) == 2
                @test engine.log[1] == (:break, "Rest", true, 0.0, 1)
                @test engine.log[2] == (:break, "Rest", true, 0.0, 3)
            end

            @testset "3. Adjustment session breaks only between confirmed trials" begin
                ex_par = ExperimentParameters("Adj", :contrast, [0.5], 3)
                m = Adjustment(dep_var = :duration_ms, dep_range = 100.0:50.0:500.0,
                                     init_interval = (200.0, 400.0))
                session = SessionContext("P03", ex_par, BaseStimulusParameters(300.0), m)
                set_messages!(session; break_every = 1, break_text = "Rest")

                # Responses [1, 1, 0, -1, 0, 0]: three confirmed trials (0 confirms)
                # Breaks fall after confirmed trials 1 and 2; trial 3 is final (FINISHED)
                engine = AdjustmentRecordingEngine()
                engine.session = session

                with_response_source(ScriptedResponseSource([1, 1, 0, -1, 0, 0])) do
                    run_experiment!(session, engine; report = :silent)
                end

                @test session.state == FINISHED
                @test length(session.history) == 3
                @test length(engine.log) == 2
                @test [e[5] for e in engine.log] == [1, 2]
            end

            @testset "4. Render-only engine falls back to response source" begin
                ex_par = ExperimentParameters("CS4", :duration_ms, [100.0, 200.0], 2)
                session = SessionContext("P04", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session; break_every = 2, break_text = "Rest", closing_text = "Done")

                # A: ScriptedResponseSource default present_message returns at once
                engine = RenderOnlyMsgEngine()
                with_response_source(ScriptedResponseSource([1, 1, 1, 1])) do
                    run_experiment!(session, engine; report = :silent)
                end
                @test session.state == FINISHED
                @test length(session.history) == 4

                # B: Custom response source recording present_message receives calls
                session2 = SessionContext("P04b", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session2; break_every = 2, break_text = "Rest", closing_text = "Done")
                rec_source = RecordingMsgSource([1, 1, 1, 1])
                with_response_source(rec_source) do
                    run_experiment!(session2, engine; report = :silent)
                end
                @test session2.state == FINISHED
                @test length(rec_source.log) == 2
                @test rec_source.log[1] == (:break, "Rest", true, 0.0)
                @test rec_source.log[2] == (:closing, "Done", true, 0.0)
            end

            @testset "5. Model observer receives no messages" begin
                params = MarkerLayout(DistrN = 4, Diff = 0.0)
                ex_par = ExperimentParameters("OK_Model", :Diff, [-10.0, 10.0], 1)
                session = SessionContext("P05", ex_par, params, ConstantStimuli())
                source = ModelObserverSource(SimulatedObserver(), length_comparison_task())
                set_task!(session, source.task)
                set_messages!(session; instructions = true, break_every = 1,
                              break_text = "Rest", closing_text = "Bye")

                engine = MessageRecordingEngine()
                engine.session = session

                run_observer_experiment!(session, source, engine; report = :silent)

                @test session.state == FINISHED
                @test length(session.history) == 2
                @test isempty(engine.log)
            end

            @testset "6. break_waits_for = :operator leaves session PAUSED until resume!" begin
                ex_par = ExperimentParameters("CS4", :duration_ms, [100.0, 200.0], 2)
                session = SessionContext("P06", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session; break_every = 2, break_waits_for = :operator,
                              break_text = "Operator break")

                engine = MessageRecordingEngine()
                engine.session = session

                task = @async run_experiment!(session, engine; report = :silent)

                # Wait until break occurs: session is PAUSED and shown_message is set
                @test timedwait(() -> session.state == PAUSED && session.shown_message !== nothing, 2.0; pollint = 0.02) == :ok
                @test session.shown_message !== nothing
                @test session.shown_message.kind == :break
                @test session.shown_message.dismissible == false
                @test length(engine.log) == 1
                @test engine.log[1][3] == false  # dismissible is false

                # Resume the session
                resume!(session)
                wait(task)

                @test session.state == FINISHED
                @test length(session.history) == 4
            end

            @testset "7. Operator ending message or aborting during break" begin
                # A: end_message! resumes a participant break that does not auto-dismiss
                ex_par = ExperimentParameters("CS4", :duration_ms, [100.0, 200.0], 2)
                session = SessionContext("P07a", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session; break_every = 2, break_waits_for = :participant,
                              break_text = "Participant break")

                engine = MessageRecordingEngine(poll_dismissible = true)
                engine.session = session

                task = @async run_experiment!(session, engine; report = :silent)

                @test timedwait(() -> session.state == PAUSED && session.shown_message !== nothing, 2.0; pollint = 0.02) == :ok
                @test session.shown_message.dismissible == true
                @test end_message!(session) == true

                wait(task)
                @test session.state == FINISHED
                @test length(session.history) == 4

                # B: abort! during break terminates loop with ABORTED
                session2 = SessionContext("P07b", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session2; break_every = 2, break_text = "Participant break")

                engine2 = MessageRecordingEngine(poll_dismissible = true)
                engine2.session = session2

                task2 = @async run_experiment!(session2, engine2; report = :silent)

                @test timedwait(() -> session2.state == PAUSED && session2.shown_message !== nothing, 2.0; pollint = 0.02) == :ok
                abort!(session2)
                wait(task2)
                @test session2.state == ABORTED
            end

            @testset "8. Persistence and replication" begin
                ex_par = ExperimentParameters("Persist", :duration_ms, [100.0], 1)
                session = SessionContext("P08", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_task!(session, length_comparison_task())
                set_messages!(session; instructions = true, break_every = 5, break_after = [2, 4],
                              break_waits_for = :operator, break_min_s = 2.5,
                              break_text = "Pause", closing_text = "Goodbye")

                # Checkpoint and load
                path = save_session_checkpoint(session, dir)
                loaded = load_session(path)
                @test loaded.messages == session.messages

                # Replication
                replicated = create_replicated_session(loaded, "P08_rep")
                @test replicated.messages == session.messages

                # A session file without a "messages" key
                raw = PsychophysicsManager.session_to_dict(session)
                delete!(raw, "messages")
                legacy = PsychophysicsManager.dict_to_session(raw)
                @test legacy.messages == SessionMessages()
            end

            @testset "9. Validation and partial updates" begin
                ex_par = ExperimentParameters("Val", :duration_ms, [100.0], 1)
                session = SessionContext("P09", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())

                # instructions without task throws
                @test_throws ArgumentError set_messages!(session; instructions = true)

                # break scheduled without break_text throws
                @test_throws ArgumentError set_messages!(session; break_every = 3)
                @test_throws ArgumentError set_messages!(session; break_after = [1], break_text = "   ")

                # invalid values throw
                @test_throws ArgumentError set_messages!(session; break_every = -1, break_text = "B")
                @test_throws ArgumentError set_messages!(session; break_after = [0], break_text = "B")
                @test_throws ArgumentError set_messages!(session; break_waits_for = :nobody, break_every = 2, break_text = "B")
                @test_throws ArgumentError set_messages!(session; break_min_s = -1.0, break_every = 2, break_text = "B")

                # partial updates keep other fields
                set_messages!(session; break_every = 2, break_text = "Break")
                @test session.messages.break_every == 2
                @test session.messages.break_text == "Break"
                @test session.messages.break_min_s == 0.0

                set_messages!(session; break_min_s = 1.5)
                @test session.messages.break_every == 2
                @test session.messages.break_text == "Break"
                @test session.messages.break_min_s == 1.5
            end

            @testset "10. Resumed session does not repeat instructions or already shown break" begin
                ex_par = ExperimentParameters("ResumeTest", :duration_ms, [100.0, 200.0], 3)
                session = SessionContext("P10", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_task!(session, length_comparison_task())
                set_messages!(session; instructions = true, break_every = 2,
                              break_text = "Break", closing_text = "Done")

                engine = MessageRecordingEngine()
                engine.session = session

                # The break after trial 2 waits for the operator, and the loop lets the
                # paused session go: it stops there, as an interrupted run does
                set_messages!(session; break_waits_for = :operator)
                run_experiment!(session, engine; report = :silent, keep_waiting = () -> false)

                @test session.state == PAUSED
                @test length(session.history) == 2
                @test length(engine.log) == 2
                @test engine.log[1][1] == :instructions
                @test engine.log[2][1] == :break && engine.log[2][5] == 2

                # Clear engine log and continue experiment
                empty!(engine.log)
                set_messages!(session; break_waits_for = :participant)
                run_experiment!(session, engine; report = :silent)

                @test session.state == FINISHED
                @test length(session.history) == 6
                # Instructions not repeated; break after 2 not repeated; break after 4 and closing after 6 shown
                @test !any(e[1] == :instructions for e in engine.log)
                @test !any(e[1] == :break && e[5] == 2 for e in engine.log)
                @test length(engine.log) == 2
                @test engine.log[1] == (:break, "Break", true, 0.0, 4)
                @test engine.log[2] == (:closing, "Done", true, 0.0, 6)
            end

            @testset "11. Undo does not repeat break and counts by recorded trials" begin
                ex_par = ExperimentParameters("UndoTest", :duration_ms, [100.0, 200.0], 3)
                session = SessionContext("P11", ex_par, BaseStimulusParameters(100.0), ConstantStimuli())
                set_messages!(session; break_every = 2, break_text = "Break")

                engine = MessageRecordingEngine()
                engine.session = session

                # Run the first 2 trials: the operator's break after trial 2 stops the loop
                set_messages!(session; break_waits_for = :operator)
                run_experiment!(session, engine; report = :silent, keep_waiting = () -> false)

                @test length(session.history) == 2
                @test length(engine.log) == 1
                @test engine.log[1] == (:break, "Break", false, 0.0, 2)
                set_messages!(session; break_waits_for = :participant)

                # Undo trial 2: marks it invalid, re-queues it
                undo_last_trial!(session)
                @test !session.history[2].is_valid

                empty!(engine.log)
                # Continue: re-presented trial will have trial_index = 3 (no break before or after 3)
                # Next break falls after recorded trial 4
                run_experiment!(session, engine; report = :silent)

                @test session.state == FINISHED
                # Next break in log must be at recorded trial 4
                @test length(engine.log) == 2
                @test engine.log[1] == (:break, "Break", true, 0.0, 4)
                @test engine.log[2] == (:break, "Break", true, 0.0, 6)
            end

            @testset "12. ChannelResponseSource timing and dismissal" begin
                ch = Channel{Tuple{Int, Float64}}(1)
                source = PsychophysicsManager.ChannelResponseSource(ch)

                @test PsychophysicsManager.shown_message(source) === nothing

                # Dismissible message with min_s = 0.2
                msg = ParticipantMessage(:break, "Break text", true, 0.2, () -> true)
                t = @async present_message(source, msg)

                @test timedwait(() -> PsychophysicsManager.shown_message(source) !== nothing, 0.5) == :ok
                @test PsychophysicsManager.shown_message(source) === msg

                # Key offered at once (< 0.2 s) must be discarded
                @test PsychophysicsManager.offer_response!(ch, 1) == true
                sleep(0.05)
                @test !istaskdone(t)

                # Key offered after 0.2 s ends the message
                sleep(0.2)
                @test PsychophysicsManager.offer_response!(ch, 1) == true
                wait(t)
                @test istaskdone(t)
                @test PsychophysicsManager.shown_message(source) === nothing

                # Non-dismissible message ends when keep_waiting returns false
                keep = Ref(true)
                non_dism = ParticipantMessage(:break, "Wait", false, 0.0, () -> keep[])
                t2 = @async present_message(source, non_dism)

                @test timedwait(() -> PsychophysicsManager.shown_message(source) !== nothing, 0.5) == :ok
                @test PsychophysicsManager.shown_message(source) === non_dism

                # Key offered does not dismiss non-dismissible message
                @test PsychophysicsManager.offer_response!(ch, 1) == true
                sleep(0.05)
                @test !istaskdone(t2)

                # Setting keep_waiting to false ends it
                keep[] = false
                wait(t2)
                @test istaskdone(t2)
                @test PsychophysicsManager.shown_message(source) === nothing
            end
        end
    end
end
