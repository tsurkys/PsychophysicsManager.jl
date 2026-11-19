using Dates
using TOML

# An engine with a window the person in front of it can close, for the dashboard's preview
mutable struct PreviewWindowEngine <: PsychophysicsManager.AbstractStimulusEngine
    open::Bool
end
PsychophysicsManager.initialize_engine(::Type{PreviewWindowEngine}, ::AbstractStimulusParameters,
                            ::DisplayConfig) = PreviewWindowEngine(true)
PsychophysicsManager.present_stimulus(::PreviewWindowEngine, ::AbstractStimulusParameters,
                           ::AbstractVector{<:Number}) = nothing
PsychophysicsManager.close_engine!(engine::PreviewWindowEngine) = (engine.open = false; nothing)
Base.isopen(engine::PreviewWindowEngine) = engine.open
register_engine_type!(PreviewWindowEngine)

# A headless engine that reads its own keys and records participant messages, for
# testing single-screen inter-trial remaining-trials display without a window.
mutable struct SingleScreenMessageEngine <: PsychophysicsManager.AbstractStimulusEngine
    controller::Union{Nothing, DashboardController}
    log::Vector{Tuple{Symbol, String, Bool, Bool}}
    SingleScreenMessageEngine(controller = nothing) =
        new(controller, Tuple{Symbol, String, Bool, Bool}[])
end
PsychophysicsManager.initialize_engine(::Type{SingleScreenMessageEngine},
                                       ::AbstractStimulusParameters,
                                       ::DisplayConfig) = SingleScreenMessageEngine()
PsychophysicsManager.reads_response_keys(::SingleScreenMessageEngine) = true
PsychophysicsManager.present_stimulus(::SingleScreenMessageEngine,
                                      ::AbstractStimulusParameters,
                                      ::AbstractVector{<:Number}) = 1
function PsychophysicsManager.present_message(engine::SingleScreenMessageEngine,
                                              msg::ParticipantMessage)
    flagged = engine.controller !== nothing && engine.controller.inter_trial_message
    push!(engine.log, (msg.kind, msg.text, msg.dismissible, flagged))
    return nothing
end
register_engine_type!(SingleScreenMessageEngine)

# A windowless render-only engine (like AudioStimulusEngine): no keys of its own, no display
struct WindowlessRenderEngine <: PsychophysicsManager.AbstractStimulusEngine end
PsychophysicsManager.present_stimulus(::WindowlessRenderEngine,
                                      ::AbstractStimulusParameters,
                                      ::AbstractVector{<:Number}) = nothing

# An open-ended method whose planned trial count is unknown
struct OpenEndedUIStubMethod <: AbstractPsychoMethod end
PsychophysicsManager.initialize_method!(::OpenEndedUIStubMethod, ::ExperimentParameters;
                                        rng = Random.default_rng()) = nothing
PsychophysicsManager.is_experiment_finished(::OpenEndedUIStubMethod) = false

# Minimal stand-in for DashboardWindow in headless `run_when_started!` tests
struct MockSingleScreenDashboard
    controller::DashboardController
    open::Ref{Bool}
end
Base.isopen(d::MockSingleScreenDashboard) = d.open[]

# Operator-UI layer. Everything here is headless by design:
# these are the dashboard's rules and wording, tested without opening a window.

@testset "Operator UI" begin

    make_session(; participant = "UI") = SessionContext(
        participant,
        ExperimentParameters("UITest", :level, [1.0, 2.0, 3.0], 2),
        BaseStimulusParameters(100.0),
        ConstantStimuli(),
    )

    @testset "Panel text" begin
        @test PsychophysicsManager.dashboard_participant_text(nothing) == PsychophysicsManager.no_session_text()
        @test PsychophysicsManager.dashboard_status_text(nothing) == PsychophysicsManager.no_session_text()
        @test PsychophysicsManager.format_dashboard_progress(nothing) == PsychophysicsManager.no_session_text()

        session = make_session(participant = "Alice")
        @test PsychophysicsManager.dashboard_participant_text(session) == "Alice"
        @test PsychophysicsManager.dashboard_status_text(session) == "READY"

        # Before the start the plan is not drawn yet; its size is the design's
        @test PsychophysicsManager.format_dashboard_progress(session) == "Valid trials: 0 / 6"
        start_session!(session)
        @test PsychophysicsManager.format_dashboard_progress(session) == "Valid trials: 0 / 6"
        # A trial is checkpointed, and the file belongs in a directory of the test's own
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                foreach(_ -> run_next_trial!(session, EmulatorEngine()), 1:3)
                @test PsychophysicsManager.format_dashboard_progress(session) == "Valid trials: 3 / 6"
                pause!(session)
                @test PsychophysicsManager.dashboard_entry_row(session).trials == "3 / 6"
                @test only(PsychophysicsManager.dashboard_previous_sessions()).trials == "3 / 6"
                resume!(session)
                @test undo_last_trial!(session) == 3
                @test PsychophysicsManager.format_dashboard_progress(session) == "Valid trials: 2 / 6"
                abort!(session)
                @test PsychophysicsManager.dashboard_entry_row(session).trials == "2 / 6"
                @test only(PsychophysicsManager.dashboard_previous_sessions()).trials == "2 / 6"
            end
        end
        @test PsychophysicsManager.trials_text(3, nothing) == "3"
        @test PsychophysicsManager.trials_text(0, nothing) == ""
    end

    @testset "Live plot specification" begin
        spec = PsychophysicsManager.dashboard_plot_spec(nothing)
        @test spec.title == PsychophysicsManager.no_session_text()
        @test spec.x_label == "" && spec.y_label == ""

        spec = PsychophysicsManager.dashboard_plot_spec(make_session())
        @test spec.title == "Psychometric Data"
        @test spec.x_label == "level"
        @test spec.y_label == "Mean Response"

        adjustment = SessionContext(
            "UI",
            ExperimentParameters("Adj", :level, [1.0, 2.0], 1),
            BaseStimulusParameters(100.0),
            Adjustment(dep_var = :duration_ms, dep_range = 0.0:10.0),
        )
        spec = PsychophysicsManager.dashboard_plot_spec(adjustment)
        @test spec.title == "Adjustment Data"
        @test spec.y_label == "Mean Adjusted Value"

        auditory = SessionContext(
            "Listener",
            ExperimentParameters("Temporal", :comparison_interval_ms,
                                 [800.0, 1000.0], 1),
            TemporalOppelKundt(),
            ConstantStimuli(),
        )
        spec = PsychophysicsManager.dashboard_plot_spec(auditory)
        @test spec.y_label == "Proportion: second interval longer"

        # Several independent variables share one axis label
        multi = SessionContext(
            "UI",
            ExperimentParameters("Multi", [:contrast, :frequency],
                                 [[0.1, 0.2], [1.0, 2.0]], 1),
            BaseStimulusParameters(100.0),
            ConstantStimuli(),
        )
        @test PsychophysicsManager.dashboard_plot_spec(multi).x_label == "contrast, frequency"

        # The axes are named in the units the session declares
        set_unit_conversion!(adjustment, :level, UnitConversion("Level (dB)"))
        set_unit_conversion!(adjustment, :duration_ms, UnitConversion("Duration (s)";
                                                                      scale = 1e-3))
        spec = PsychophysicsManager.dashboard_plot_spec(adjustment)
        @test spec.x_label == "Level (dB)"
        @test spec.y_label == "Duration (s)"
    end

    @testset "Available actions" begin
        controller = DashboardController()
        available = PsychophysicsManager.action_state(controller)
        @test available.can_load
        @test !available.can_start && !available.can_pause && !available.can_resume
        @test !available.can_undo

        # A dashboard attached to a script's session cannot load another one
        session = make_session()
        attached = DashboardController(session)
        @test !attached.owns_engine
        @test !PsychophysicsManager.action_state(attached).can_load
        @test PsychophysicsManager.action_state(attached).can_start   # READY

        start_session!(session)
        available = PsychophysicsManager.action_state(attached)
        @test !available.can_start && available.can_pause && !available.can_resume

        pause!(session)
        available = PsychophysicsManager.action_state(attached)
        @test available.can_resume && !available.can_pause

        # Undo needs something to undo
        @test !PsychophysicsManager.action_state(attached).can_undo
        push!(session.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        @test PsychophysicsManager.action_state(attached).can_undo

        # ...and no trial under way; a press that comes anyway is told why
        session.trial_under_way = true
        @test !PsychophysicsManager.action_state(attached).can_undo
        PsychophysicsManager.undo_dashboard_trial!(attached)
        @test attached.message == ui_label(:msg_undo_during_trial)
        @test session.history[1].is_valid
        session.trial_under_way = false
    end

    @testset "Fit asymptote control" begin
        # Without a session there is nothing to declare it about
        controller = DashboardController()
        available = PsychophysicsManager.action_state(controller)
        @test !available.can_set_fit_gamma
        @test available.fit_gamma == PsychophysicsManager.DEFAULT_FIT_GAMMA
        PsychophysicsManager.set_dashboard_fit_gamma!(controller, 0.5)
        @test controller.message == PsychophysicsManager.no_session_text()

        session = make_session()
        controller = DashboardController(session)
        @test PsychophysicsManager.action_state(controller).can_set_fit_gamma
        @test PsychophysicsManager.action_state(controller).fit_gamma == 0.0

        # The controller keeps no copy: the session is the single source of
        # truth, which is also what persists the choice
        PsychophysicsManager.set_dashboard_fit_gamma!(controller, 0.5)
        @test session.fit_gamma == 0.5
        @test PsychophysicsManager.action_state(controller).fit_gamma == 0.5
        @test occursin("forced choice", controller.message)

        # Labels name the values the dashboard offers; the values are the state
        @test PsychophysicsManager.fit_gamma_label(0.0) == "Threshold or detection (curve from 0)"
        @test PsychophysicsManager.fit_gamma_label(0.5) == "Two-alternative forced choice (curve from 0.5)"
        @test [value for (value, _) in PsychophysicsManager.FIT_GAMMA_CHOICES] == [0.0, 0.5]
        # A value set from a script is still displayed rather than hidden
        @test PsychophysicsManager.fit_gamma_label(0.25) == "0.25"

        # Observers are told, so an attached dashboard follows a change made
        # from a script — but as a setting, not a lifecycle state change
        events = Symbol[]
        watched = make_session()
        start_session!(watched)
        on_session_event!((_, event) -> push!(events, event), watched)
        set_fit_gamma!(watched, 0.5)
        @test events == [:settings_changed]
        # An unchanged value is not an event
        set_fit_gamma!(watched, 0.5)
        @test events == [:settings_changed]

        # A running session's console reporter stays quiet: reporting this as
        # a state change would reprint the session banner mid-run
        mktempdir() do dir
            reported = make_session()
            start_session!(reported)
            attach_console_reporter!(reported; level = :trials)
            out_path = joinpath(dir, "reporter_out.txt")
            open(out_path, "w") do io
                redirect_stdout(io) do
                    set_fit_gamma!(reported, 0.5)
                end
            end
            @test isempty(strip(read(out_path, String)))
        end
    end

    @testset "Session binding" begin
        controller = DashboardController()
        refreshes = Ref(0)
        controller.on_update = () -> refreshes[] += 1

        first_session = make_session()
        PsychophysicsManager.bind_session!(controller, first_session)
        @test controller.session === first_session
        @test length(first_session.listeners) == 1

        # Rebinding must not leave an observer behind on the old session
        second_session = make_session()
        PsychophysicsManager.bind_session!(controller, second_session)
        @test controller.session === second_session
        @test isempty(first_session.listeners)
        @test length(second_session.listeners) == 1

        before = refreshes[]
        start_session!(second_session)          # emits :state_changed
        @test refreshes[] > before

        PsychophysicsManager.unbind_session!(controller)
        @test controller.session === nothing
        @test isempty(second_session.listeners)

        # A failing view is logged, never propagated into the experiment
        controller.on_update = () -> error("view crashed")
        @test (@test_logs (:warn, r"Dashboard view refresh failed") PsychophysicsManager.notify_view(controller)) === nothing
    end

    @testset "Response source is restored on close" begin
        original = PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[]
        controller = DashboardController()
        dashboard_source = ScriptedResponseSource([1])

        PsychophysicsManager.install_response_source!(controller, dashboard_source)
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === dashboard_source

        # Installing twice still remembers the source the dashboard replaced
        PsychophysicsManager.install_response_source!(controller, ScriptedResponseSource([0]))
        PsychophysicsManager.close_controller!(controller)
        @test PsychophysicsManager.ACTIVE_RESPONSE_SOURCE[] === original
    end

    @testset "Recent messages are kept" begin
        controller = DashboardController()
        @test isempty(controller.messages)
        PsychophysicsManager.set_message!(controller, "first")
        PsychophysicsManager.set_message!(controller, "second")
        @test last.(controller.messages) == ["first", "second"]
        @test controller.message == "second"
        @test issorted(first.(controller.messages))
        for k in 1:PsychophysicsManager.MESSAGE_HISTORY
            PsychophysicsManager.set_message!(controller, "m$k")
        end
        @test length(controller.messages) == PsychophysicsManager.MESSAGE_HISTORY
        @test last(controller.messages[end]) == "m$(PsychophysicsManager.MESSAGE_HISTORY)"
    end

    @testset "Guarded actions without a session" begin
        controller = DashboardController()
        @test PsychophysicsManager.start_experiment!(controller) == false
        @test controller.message == PsychophysicsManager.no_session_text()

        PsychophysicsManager.set_message!(controller, "x")
        PsychophysicsManager.pause_experiment!(controller)
        @test controller.message == PsychophysicsManager.no_session_text()

        PsychophysicsManager.set_message!(controller, "x")
        PsychophysicsManager.resume_experiment!(controller)
        @test controller.message == PsychophysicsManager.no_session_text()

        PsychophysicsManager.set_message!(controller, "x")
        PsychophysicsManager.undo_dashboard_trial!(controller)
        @test controller.message == PsychophysicsManager.no_session_text()

        PsychophysicsManager.set_message!(controller, "x")
        @test PsychophysicsManager.end_dashboard_message!(controller) == false
        @test controller.message == PsychophysicsManager.no_session_text()
    end

    @testset "Undo reports into the panel" begin
        session = make_session()
        start_session!(session)
        push!(session.history, Trial(1, 0.0, 0.1, [1.0], 1, true))
        controller = DashboardController(session)

        PsychophysicsManager.undo_dashboard_trial!(controller)
        @test !session.history[1].is_valid
        @test occursin("Trial 1", controller.message)

        # A refused or impossible undo is reported too, never silently ignored
        PsychophysicsManager.undo_dashboard_trial!(controller)
        @test occursin("Nothing", controller.message)
    end

    @testset "Interface text comes from the locale files" begin
        locale(language) = TOML.parsefile(joinpath(PsychophysicsManager.LOCALE_DIRECTORY,
                                                   "$language.toml"))
        placeholders(text) = sort([m.captures[1] for m in eachmatch(r"\{(\w+)\}", text)])
        english = locale("en")

        # Every key the interface asks for is in the reference file: the ones
        # named in the code, and the ones composed from a state or a choice
        root = pkgdir(PsychophysicsManager)
        sources = vcat([joinpath(dir, file) for dir in (joinpath(root, "src", "UI"),
                                                        joinpath(root, "ext", "PsychophysicsManagerImGuiExt"))
                        for file in readdir(dir) if endswith(file, ".jl")])
        used = Set(m.captures[1] for file in sources
                   for m in eachmatch(r"ui_label\(:(\w+)", read(file, String)))
        union!(used, ["state_" * lowercase(string(state)) for state in instances(SessionState)])
        union!(used, ["policy_" * string(policy) for policy in PsychophysicsManager.UPDATE_POLICIES])
        union!(used, ["spread_" * string(spread) for spread in PsychophysicsManager.PLOT_SPREADS])
        union!(used, ["split_" * string(split) for split in PsychophysicsManager.PLOT_SPLITS])
        union!(used, [string(key) for (_, key) in PsychophysicsManager.FIT_GAMMA_CHOICES])
        union!(used, ["view_" * view for view in ("control", "plot", "trials", "messages",
                                                  "settings")])
        # The Settings view explains each setting by a text named after it
        union!(used, [string(row.tip) for section in PsychophysicsManager.dashboard_settings()
                      for row in section.rows])
        # The facts a dataset compares, and its optional checks with their tooltips
        facts = first.(PsychophysicsManager.combining_facts(make_session(), COMBINING_CHECKS))
        union!(used, ["fact_" * string(fact) for fact in facts])
        union!(used, [prefix * string(check) for check in COMBINING_CHECKS
                      for prefix in ("check_", "tip_check_")])
        # The tooltips are named by symbol, not by a ui_label call
        union!(used, Set(m.captures[1] for file in sources
                         for m in eachmatch(r"tooltip\(:(\w+)", read(file, String))))
        @test isempty(setdiff(used, keys(english)))

        # A translation has the same keys, and the same placeholders in each
        translations = [first(splitext(file)) for file in readdir(PsychophysicsManager.LOCALE_DIRECTORY)
                        if endswith(file, ".toml") && file != "en.toml"]
        @test "lt" in translations
        for language in translations
            translated = locale(language)
            @test sort(collect(keys(translated))) == sort(collect(keys(english)))
            @test all(key -> placeholders(translated[key]) == placeholders(english[key]),
                      intersect(keys(translated), keys(english)))
        end

        try
            set_ui_language!("lt")
            @test ui_language() == "lt"
            @test ui_label(:msg_outlier_marked; trial = 3) ==
                  "Bandymas 3 pažymėtas kaip išskirtis."
            session = make_session()
            @test PsychophysicsManager.dashboard_status_text(session) == "PARUOŠTA"
            @test PsychophysicsManager.format_dashboard_progress(session) == "Galiojantys bandymai: 0 / 6"

            # What a language lacks is English, and so is a language with no file
            PsychophysicsManager.LOCALE_TABLES["xx"] = Dict("stop" => "Halt")
            set_ui_language!("xx")
            @test ui_label(:stop) == "Halt"
            @test ui_label(:pause) == "Pause"
            set_ui_language!("zz")
            @test (@test_logs (:warn, r"no interface text") ui_label(:pause)) == "Pause"
            @test ui_label(:no_such_text) == "no_such_text"
        finally
            delete!(PsychophysicsManager.LOCALE_TABLES, "xx")
            delete!(PsychophysicsManager.LOCALE_TABLES, "zz")
            set_ui_language!("en")
        end

        # The language comes from the settings when none was set
        mktempdir() do dir
            cd(dir) do
                @test PsychophysicsManager.load_ui_language() == "en"
                write("settings.toml", "[ui]\nlanguage = \"lt\"\n")
                @test PsychophysicsManager.load_ui_language() == "lt"
                try
                    set_ui_language!(nothing)
                    @test ui_language() == "lt"
                finally
                    set_ui_language!("en")
                end
                write("settings.toml", "[ui]\nlanguage = 7\n")
                @test (@test_logs (:warn, r"cannot be 7") PsychophysicsManager.load_ui_language()) == "en"
            end
        end
        @test ui_language() == "en"
    end

    @testset "The update policy decides what redraws the view" begin
        refresh = PsychophysicsManager.should_refresh
        # Within a trial only continuous; a completed trial all but minimal
        @test refresh(:continuous, :response_registered)
        @test !refresh(:between_trials, :response_registered)
        @test !refresh(:minimal, :response_registered)
        @test refresh(:between_trials, :trial_completed)
        @test !refresh(:minimal, :trial_completed)
        for event in (:state_changed, :history_changed, :settings_changed, :interrupted),
            policy in PsychophysicsManager.UPDATE_POLICIES
            @test refresh(policy, event)
        end

        @test_throws ArgumentError DashboardController(; update_policy = :sometimes)
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                session = make_session()
                controller = DashboardController(session; update_policy = :minimal)
                redraws = Ref(0)
                controller.on_update = () -> (redraws[] += 1)
                PsychophysicsManager.bind_session!(controller, session)
                redraws[] = 0

                # A skipped event does no work at all inside the loop
                start_session!(session)
                @test redraws[] == 1
                run_next_trial!(session, EmulatorEngine())
                @test redraws[] == 1

                PsychophysicsManager.set_update_policy!(controller, :between_trials)
                @test controller.update_policy === :between_trials
                @test occursin("between trials", controller.message)
                redraws[] = 0
                run_next_trial!(session, EmulatorEngine())
                @test redraws[] == 1
                @test_throws ArgumentError PsychophysicsManager.set_update_policy!(controller, :never)
                @test controller.update_policy === :between_trials
            end
        end
    end

    @testset "Stop waits for a second press; a discard is of a file" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                session = make_session()
                controller = DashboardController(session)
                available = PsychophysicsManager.action_state(controller)
                @test !available.can_stop && !available.can_discard   # READY, no file

                start_session!(session)
                run_next_trial!(session, EmulatorEngine())
                available = PsychophysicsManager.action_state(controller)
                @test available.can_stop && available.can_discard

                # One press only says what a second will do
                @test PsychophysicsManager.stop_experiment!(controller) == false
                @test session.state == RUNNING
                @test occursin("again", controller.message)
                # A press long after the first asks again
                controller.armed_at -= 2 * PsychophysicsManager.CONFIRM_WINDOW_S
                @test PsychophysicsManager.stop_experiment!(controller) == false
                @test PsychophysicsManager.stop_experiment!(controller)
                @test session.state == ABORTED
                @test controller.message == "Session stopped."
                @test !PsychophysicsManager.action_state(controller).can_stop

                # The session in hand is set aside by its file, and stays shown
                file = session.save_path
                @test PsychophysicsManager.action_state(controller).can_discard
                @test PsychophysicsManager.discard_dashboard_file!(controller, file)
                @test !isfile(file) && is_discarded(session.save_path)
                @test occursin(session.save_path, controller.message)
                @test PsychophysicsManager.dashboard_status_text(session) == "STOPPED (discarded)"
                @test !PsychophysicsManager.action_state(controller).can_discard

                # Another file is set aside without touching the session in hand; a
                # running one is stopped first
                other = make_session(participant = "Other")
                start_session!(other)
                run_next_trial!(other, EmulatorEngine())
                other_file = other.save_path
                @test PsychophysicsManager.discard_dashboard_file!(controller, other_file)
                @test !isfile(other_file) && session.state == ABORTED
                @test PsychophysicsManager.discard_dashboard_file!(controller, other_file) == false
                running = make_session(participant = "Running")
                start_session!(running)
                run_next_trial!(running, EmulatorEngine())
                PsychophysicsManager.bind_session!(controller, running)
                @test PsychophysicsManager.discard_dashboard_file!(controller, running.save_path)
                @test running.state == ABORTED && is_discarded(running.save_path)
            end
        end
    end

    @testset "Corrections of one trial, from the plot or the table" begin
        session = make_session()
        start_session!(session)
        controller = DashboardController(session)
        @test !PsychophysicsManager.action_state(controller).can_mark_outlier
        push!(session.history, Trial(1, 0.0, 0.1, [1.0], 1, true),
              Trial(2, 0.2, 0.3, [2.0], 1, true))
        @test PsychophysicsManager.action_state(controller).can_mark_outlier
        @test PsychophysicsManager.trial_actions(controller, 2) ==
              (can_mark_outlier = true, can_repeat = true, can_add = true, can_now = false)
        @test PsychophysicsManager.trial_actions(controller, 7) ==
              (can_mark_outlier = false, can_repeat = false, can_add = false, can_now = false)

        @test PsychophysicsManager.mark_dashboard_outlier!(controller, 7) == false
        @test controller.message == "There is no trial 7."
        @test PsychophysicsManager.mark_dashboard_outlier!(controller, 2)
        @test !session.history[2].is_valid && session.history[1].is_valid
        @test controller.message == "Trial 2 marked as an outlier."
        @test PsychophysicsManager.mark_dashboard_outlier!(controller, 2) == false
        @test occursin("already", controller.message)
        # A trial that no longer counts has no answer left to replace; its condition
        # can still be presented again
        @test PsychophysicsManager.trial_actions(controller, 2) ==
              (can_mark_outlier = false, can_repeat = false, can_add = true, can_now = false)

        # A repetition asked for during a trial waits for that trial to be answered;
        # the earlier answer counts until the new one is recorded, and the trial is
        # not offered twice. Presenting now needs a trial that awaits its answer.
        session.trial_under_way = true
        session.trial_run = PsychophysicsManager.TrialRun(current_task(), EmulatorEngine())
        @test PsychophysicsManager.trial_actions(controller, 1) ==
              (can_mark_outlier = true, can_repeat = true, can_add = true, can_now = true)
        @test PsychophysicsManager.repeat_dashboard_trial!(controller, 1)
        @test controller.message == ui_label(:msg_replace_next; trial = 1)
        @test session.history[1].is_valid
        @test !PsychophysicsManager.trial_actions(controller, 1).can_repeat
        session.trial_under_way = false
        session.trial_run = nothing
        @test PsychophysicsManager.repeat_dashboard_trial!(controller, 9) == false
        @test controller.message == "There is no trial 9."

        # Adding, and a condition chosen from the plot, go to the queue as well
        @test PsychophysicsManager.add_dashboard_trial!(controller, 2)
        @test controller.message == ui_label(:msg_add_next; trial = 2)
        @test PsychophysicsManager.present_dashboard_condition!(controller, [3.0])
        @test controller.message == ui_label(:msg_condition_next)
        @test [(r.vals, r.replaces) for r in session.operator_requests] ==
              [([1.0], 1), ([2.0], nothing), ([3.0], nothing)]

        # A script's loop ends with its session: a finished session it ran presents
        # nothing more from the dashboard
        session.state = FINISHED
        @test !PsychophysicsManager.can_present(controller)
        @test PsychophysicsManager.trial_actions(controller, 1).can_add == false
        @test PsychophysicsManager.present_dashboard_condition!(controller, [3.0]) == false
        @test controller.message == ui_label(:msg_finished_script)
        session.state = RUNNING

        # A stopped session is not measured again
        push!(session.history, Trial(3, 0.4, 0.5, [3.0], 1, true))
        abort!(session)
        @test PsychophysicsManager.trial_actions(controller, 3) ==
              (can_mark_outlier = true, can_repeat = false, can_add = false, can_now = false)
    end

    @testset "The plot's menus name conditions as recorded" begin
        session = SessionContext("C", ExperimentParameters("2IFC", [:level, :target_interval],
                                                           Any[[2.0, 1.0], [1, 2]], 1),
                                 BaseStimulusParameters(100.0), ConstantStimuli())
        @test PsychophysicsManager.dashboard_design_conditions(session) ==
              ["level 1 · target_interval 1" => [1.0, 1.0],
               "level 1 · target_interval 2" => [1.0, 2.0],
               "level 2 · target_interval 1" => [2.0, 1.0],
               "level 2 · target_interval 2" => [2.0, 2.0]]
        # A point is drawn in the declared units; presenting it again uses the values
        # the session recorded
        set_unit_conversion!(session, :level, UnitConversion("Level (dB)"; scale = 10.0))
        push!(session.history, Trial(1, 0.0, 0.1, [2.0, 1.0], 1, true))
        point = only(get_aggregated_data(session))
        @test point.level == 20.0
        @test PsychophysicsManager.dashboard_point_condition(session, point) == [2.0, 1.0]
    end

    @testset "Trial table" begin
        @test isempty(PsychophysicsManager.dashboard_trial_rows(nothing))
        @test isempty(PsychophysicsManager.dashboard_trial_headers(nothing))
        session = make_session()
        @test PsychophysicsManager.dashboard_trial_headers(session) == ["No.", "level", "Answer", "Answered", "Mark"]
        push!(session.history, Trial(1, 0.0, 0.0, [800.0], 1, true),
              Trial(2, 1.0, 1.0, [1.25], :timeout, true),
              Trial(3, 2.0, 2.0, [2.0], 0, false, :engine, true),
              Trial(4, 3.0, 3.0, [2.0], 1, true, :engine, false))
        rows = PsychophysicsManager.dashboard_trial_rows(session)
        @test [row.trial for row in rows] == [1, 2, 3, 4]
        @test rows[1].values == ["800"] && rows[2].values == ["1.25"]
        @test rows[1].response == "1"
        @test rows[2].response == ui_label(:response_timeout)
        @test rows[3].response == "0 · correct" && rows[4].response == "1 · wrong"
        @test [row.counted for row in rows] == [true, true, false, true]
        # Local time of day, as the operator's clock shows it
        @test rows[1].answered_at == Libc.strftime("%H:%M:%S", 0.0)
    end

    @testset "The key guide follows the task" begin
        generic = PsychophysicsManager.response_key_guide(make_session())
        @test first.(generic) == ["←", "→", "Enter / Space"]
        @test last.(generic) == ["answer −1", "answer +1", "answer 0"]
        @test PsychophysicsManager.response_key_guide(nothing) == generic

        adjustment = SessionContext("A", ExperimentParameters("Adj", :x, [1.0], 1),
                                    BaseStimulusParameters(100.0), Adjustment(dep_var = :x, dep_range = 0:1:5))
        @test last.(PsychophysicsManager.response_key_guide(adjustment)) == ["adjust", "confirm"]

        auditory = SessionContext("B", ExperimentParameters("OK", :comparison_interval_ms,
                                                            [800.0, 1200.0], 1),
                                  TemporalOppelKundt(), ConstantStimuli())
        @test last.(PsychophysicsManager.response_key_guide(auditory)) ==
              ["first interval longer", "second interval longer", "play again"]

        gabor = SessionContext("C", ExperimentParameters("2IFC", [:contrast, :target_interval],
                                                         Any[[0.1], [1, 2]], 1),
                               Gabor(), ConstantStimuli())
        @test last.(PsychophysicsManager.response_key_guide(gabor)) ==
              ["first interval", "second interval", "show again"]

        # The console prints the same guide, in English whatever the dashboard speaks,
        # when a session starts on an engine whose window reads the keys
        english = PsychophysicsManager.english_label
        try
            set_ui_language!("lt")
            @test PsychophysicsManager.response_key_guide(adjustment; label = english) ==
                  ["← / →" => "adjust", "Enter / Space" => "confirm"]
        finally
            set_ui_language!("en")
        end
        banner(session; keys) = mktempdir() do dir
            path = joinpath(dir, "banner.txt")
            open(path, "w") do io
                redirect_stdout(io) do
                    attach_console_reporter!(session; level = :session, keys)
                    start_session!(session)
                end
            end
            read(path, String)
        end
        @test occursin("Keys: ← / → adjust · Enter / Space confirm", banner(adjustment; keys = true))
        @test !occursin("Keys:", banner(make_session(); keys = false))
        # An engine that only presents, or answers for a program, has no keys
        @test !PsychophysicsManager.reads_response_keys(EmulatorEngine())
    end

    @testset "Live plot series" begin
        empty_series = PsychophysicsManager.dashboard_plot_series(nothing)
        @test isempty(empty_series.x) && empty_series.x_limits === nothing

        # Before any trial the axis already spans the design's levels
        session = make_session()
        series = PsychophysicsManager.dashboard_plot_series(session)
        @test isempty(series.x)
        low, high = series.x_limits
        @test low < 1.0 && high > 3.0
        # A few levels mark the axis, each at its value; many leave it to the library
        @test series.x_ticks == [1.0, 2.0, 3.0]
        many = SessionContext("UI", ExperimentParameters("UITest", :level, collect(0.0:20.0), 1),
                              BaseStimulusParameters(100.0), ConstantStimuli())
        @test isempty(PsychophysicsManager.dashboard_plot_series(many).x_ticks)

        # The mean response per level, with its standard error, and a fitted
        # logistic once there are enough levels and the answers determine one
        for (index, (level, response)) in enumerate([(1.0, 0), (1.0, 1), (2.0, 0), (2.0, 1),
                                                     (3.0, 1), (3.0, 1)])
            push!(session.history, Trial(index, 0.0, 0.1, [level], response, true))
        end
        series = PsychophysicsManager.dashboard_plot_series(session)
        @test series.x == [1.0, 2.0, 3.0]
        @test series.y == [0.5, 0.5, 1.0]
        @test series.err ≈ [0.5, 0.5, 0.0]
        @test length(series.curve_x) == length(series.curve_y) == 100
        @test first(series.curve_x) == low && last(series.curve_x) == high
        @test series.spec.y_label == ui_label(:plot_mean_response_y)
        @test series.y_limits == PsychophysicsManager.PROPORTION_LIMITS

        # Every trial is drawn at its own answer, the trials of a level spread sideways
        # in the order presented, within a third of the gap between levels
        @test [t.trial for t in series.trials] == 1:6
        @test [t.y for t in series.trials] == [0.0, 1.0, 0.0, 1.0, 1.0, 1.0]
        @test [t.level for t in series.trials] == [1.0, 1.0, 2.0, 2.0, 3.0, 3.0]
        @test [t.x for t in series.trials] ≈ [1 - 1/12, 1 + 1/12, 2 - 1/12, 2 + 1/12,
                                              3 - 1/12, 3 + 1/12]
        @test all(t -> low < t.x - 1/12 && t.x + 1/12 < high, series.trials)
        @test all(t -> t.counted, series.trials) && series.trials[4].answer == "1"

        # Two levels are too few for a curve
        few = make_session()
        push!(few.history, Trial(1, 0.0, 0.1, [1.0], 0, true), Trial(2, 0.0, 0.1, [2.0], 1, true))
        @test isempty(PsychophysicsManager.dashboard_plot_series(few).curve_x)

        # Before any trial is recorded the design says whether the task is scored
        scored_empty = SessionContext("C", ExperimentParameters("2IFC",
                                                                [:contrast, :target_interval],
                                                                Any[[0.1, 0.2], [1, 2]], 1),
                                      Gabor(), ConstantStimuli())
        @test PsychophysicsManager.dashboard_plot_series(scored_empty).spec.y_label ==
              ui_label(:plot_proportion_correct_y)
        @test PsychophysicsManager.dashboard_plot_series(make_session()).spec.y_label ==
              ui_label(:plot_mean_response_y)
        # Designs with no variables or refused by their stimulus still plot without throwing
        no_vars = SessionContext("C", ExperimentParameters("Empty", Symbol[], Any[], 1),
                                 Gabor(), ConstantStimuli())
        @test !PsychophysicsManager.answers_scored(no_vars)
        @test PsychophysicsManager.dashboard_plot_series(no_vars).spec.y_label ==
              ui_label(:plot_mean_response_y)
        bad_scored = SessionContext("C", ExperimentParameters("Bad", :contrast, [0.1, 0.2], 1),
                                    Gabor(), ConstantStimuli())
        @test PsychophysicsManager.dashboard_plot_series(bad_scored).spec.y_label ==
              ui_label(:plot_mean_response_y)

        # A scored task plots the proportion correct, which spreads binomially
        scored = make_session()
        for (index, (level, correct)) in enumerate([(1.0, false), (1.0, true), (2.0, true), (2.0, true)])
            push!(scored.history, Trial(index, 0.0, 0.1, [level], 1, true, :engine, correct))
        end
        series = PsychophysicsManager.dashboard_plot_series(scored)
        @test series.y == [0.5, 1.0]
        @test series.err ≈ [sqrt(0.25 / 2), 0.0]
        @test series.spec.y_label == ui_label(:plot_proportion_correct_y)
        # ...and its single trials at their correctness, not at the interval answered
        @test [t.y for t in series.trials] == [0.0, 1.0, 1.0, 1.0]
        # Before any trial counts, the recorded ones say the task is scored
        foreach(t -> t.is_valid = false, scored.history)
        series = PsychophysicsManager.dashboard_plot_series(scored)
        @test isempty(series.x) && [t.y for t in series.trials] == [0.0, 1.0, 1.0, 1.0]
        @test !any(t -> t.counted, series.trials)
        @test series.spec.y_label == ui_label(:plot_proportion_correct_y)

        # A trial answered outside 0…1 frees the y axis, though the means stay inside;
        # a trial without a number has no place on the plot
        codes = make_session()
        for (index, (level, response)) in enumerate([(1.0, 1), (1.0, 1), (2.0, 1), (2.0, -1),
                                                     (3.0, NaN)])
            push!(codes.history, Trial(index, 0.0, 0.1, [level], response, true))
        end
        push!(codes.history, Trial(6, 0.0, 0.1, [3.0], :timeout, true))
        series = PsychophysicsManager.dashboard_plot_series(codes)
        @test series.y == [1.0, 0.0] && series.y_limits === nothing
        @test [t.trial for t in series.trials] == 1:4

        # An adjustment plots the mean adjusted value and fits nothing
        adjustment = SessionContext("A", ExperimentParameters("Adj", :x, [1.0, 2.0, 3.0], 1),
                                    BaseStimulusParameters(100.0), Adjustment(dep_var = :x, dep_range = 0:1:5))
        for (index, level) in enumerate([1.0, 2.0, 3.0])
            push!(adjustment.history, Trial(index, 0.0, 0.1, [level], 2.0 * level, true))
        end
        series = PsychophysicsManager.dashboard_plot_series(adjustment)
        @test series.y == [2.0, 4.0, 6.0] && isempty(series.curve_x)
        @test [t.y for t in series.trials] == [2.0, 4.0, 6.0] && series.y_limits === nothing

        # A point leads back to every trial behind it, counted or not, in the
        # declared units the plot uses
        set_unit_conversion!(session, :level, UnitConversion("Level (dB)"; scale = 10.0))
        push!(session.history, Trial(7, 0.0, 0.1, [2.0], 1, false))
        point = only(filter(p -> p.level == 20.0, get_aggregated_data(session)))
        @test [t.trial_index for t in PsychophysicsManager.dashboard_point_trials(session, point)] == [3, 4, 7]
        series = PsychophysicsManager.dashboard_plot_series(session)
        @test series.x_limits[1] < 10.0
        # A trial that no longer counts is still drawn, at its level in those units
        set_aside = only(filter(t -> !t.counted, series.trials))
        @test set_aside.trial == 7 && set_aside.level == 20.0
    end

    @testset "A script's loop waits for Start" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                # Anything `isopen` answers for stands in for the window
                closed_window = Channel{Nothing}(1)
                close(closed_window)

                # Closing the window before Start leaves the session untouched
                session = make_session()
                @test run_when_started!(session, EmulatorEngine(), closed_window;
                                        report = :silent) === session
                @test session.state == READY && isempty(session.history)

                # Start pressed in the window releases the loop, which runs here
                dashboard = Channel{Nothing}(1)
                controller = DashboardController(session)
                @async (sleep(0.2); PsychophysicsManager.start_experiment!(controller))
                run_when_started!(session, EmulatorEngine(), dashboard; report = :silent)
                @test session.state == FINISHED
                @test length(session.history) == 6
            end
        end
    end

    @testset "A window's keys wait in its channel" begin
        channel = Channel{Tuple{Int, Float64}}(1)
        # Nothing was pressed: the wait ends at the deadline and says so
        @test PsychophysicsManager.await_channel_response(channel, 0.2) === nothing

        # One press waits; a second one is not queued behind it
        @test PsychophysicsManager.offer_response!(channel, 1)
        @test PsychophysicsManager.offer_response!(channel, -1) == false
        response, stamp = PsychophysicsManager.await_channel_response(channel, 0.2)
        @test response == 1 && abs(stamp - time()) < 5

        # A key pressed too late is still in the channel, and answers the next
        # presentation instead of being consumed by an abandoned taker
        put!(channel, (-1, 6.0))
        @test PsychophysicsManager.await_channel_response(channel, nothing) == (-1, 6.0)

        # A press made too soon is dropped, and the wait goes on within the window
        put!(channel, (1, 1.0))
        @async (sleep(0.1); put!(channel, (-1, 7.0)))
        @test PsychophysicsManager.await_channel_response(channel, 2.0; earliest = 5.0) ==
              (-1, 7.0)
        put!(channel, (1, 1.0))
        @test PsychophysicsManager.await_channel_response(channel, 0.2; earliest = 5.0) === nothing
        @test !isready(channel)
        put!(channel, (1, 1.0))
        @async (sleep(0.1); put!(channel, (0, 8.0)))
        @test PsychophysicsManager.await_channel_response(channel, nothing; earliest = 5.0) ==
              (0, 8.0)
    end

    @testset "Starting a session" begin
        # Without engine ownership the dashboard only releases the session:
        # the script that built it owns the engine and the trial loop
        session = make_session()
        attached = DashboardController(session)
        @test PsychophysicsManager.start_experiment!(attached)
        @test session.state == RUNNING
        @test attached.run_task === nothing

        # A session that is not READY is refused with a reason
        @test PsychophysicsManager.start_experiment!(attached) == false
        @test occursin("READY", attached.message)
    end

    @testset "The Start view: choosing what to run" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                @test resolve_templates_dir() == joinpath(realpath(dir), "setups")
                @test isempty(PsychophysicsManager.dashboard_templates())

                template = SessionContext("Template",
                    ExperimentParameters("Contrast", [:contrast, :target_interval],
                                         Any[[0.1, 0.2, 0.4], [1, 2]], 1),
                    Gabor(sigma_px = 12.5), ConstantStimuli(); tags = ["pilot"])
                template.engine_name = "EmulatorEngine"
                set_feedback!(template, true)
                save_session_checkpoint(template, resolve_templates_dir(); filename = "Gabor.json")
                rows = PsychophysicsManager.dashboard_templates()
                @test [row.name for row in rows] == ["Gabor"]
                @test rows[1].method == "ConstantStimuli" && rows[1].stimulus == "Gabor"

                # The parameters: the settings, and every stimulus parameter, one the
                # design sets marked as such
                setup = PsychophysicsManager.dashboard_setup_rows(template)
                shown(rows) = [row.label => row.value for row in rows]
                @test (ui_label(:setup_experiment) => "Contrast") in shown(setup.experiment)
                @test (ui_label(:setup_independent) => "contrast") in shown(setup.experiment)
                @test ("    " * ui_label(:setup_levels) => "0.1, 0.2, 0.4") in shown(setup.experiment)
                @test (ui_label(:setup_dependent) => ui_label(:measure_correct)) in
                      shown(setup.experiment)
                @test (ui_label(:setup_task) => PsychophysicsManager.fit_gamma_label(0.0)) in
                      shown(setup.experiment)
                @test (ui_label(:setup_repeats) => "1") in shown(setup.experiment)
                @test (ui_label(:setup_feedback) => ui_label(:yes)) in shown(setup.experiment)
                sigma = only(filter(row -> row.label == "sigma_px", setup.stimulus))
                @test sigma.value == "12.5" && sigma.key == "stim_par.sigma_px"
                contrast = only(filter(row -> row.label == "contrast", setup.stimulus))
                @test contrast.value == ui_label(:set_by_design) && contrast.key == "preview.contrast"
                @test [row.label for row in setup.stimulus] == collect(string.(fieldnames(Gabor)))
                adjustment = SessionContext("A", ExperimentParameters("Adj", :x, [1.0], 1),
                    BaseStimulusParameters(100.0),
                    Adjustment(dep_var = :duration_ms, dep_range = 0:10:500))
                rows_adj = PsychophysicsManager.dashboard_setup_rows(adjustment)
                @test (ui_label(:setup_dependent) => "duration_ms") in shown(rows_adj.experiment)
                @test ("    dep_range" => "0, 10, 20, …, 500  (" *
                       ui_label(:setup_values; count = 51) * ")") in shown(rows_adj.experiment)
                @test shown(rows_adj.stimulus) == ["duration_ms" => ui_label(:set_by_method)]

                # Choosing prepares a new session for the participant, who can still be
                # changed until the session starts
                register_participant!("P07")
                @test PsychophysicsManager.dashboard_participants() == [DEFAULT_PARTICIPANT_ID, "P07"]
                controller = DashboardController()
                PsychophysicsManager.set_dashboard_participant!(controller, "P07")
                @test PsychophysicsManager.control_buttons(controller) == [:start]
                @test PsychophysicsManager.choose_setup!(controller, rows[1].path)
                session = controller.session
                @test session.state == READY && session.participant_id == "P07"
                @test PsychophysicsManager.control_buttons(controller) == [:start]
                @test isempty(session.history) && controller.chosen == rows[1].path
                PsychophysicsManager.set_dashboard_participant!(controller, " P08 ")
                @test session.participant_id == "P08"
                @test PsychophysicsManager.choose_setup!(controller, "nowhere.json") == false
                @test controller.chosen === nothing
                @test occursin("Could not load", controller.message)

                # Saved as a template: no trials, no participant, never over another
                @test PsychophysicsManager.choose_setup!(controller, rows[1].path)
                @test PsychophysicsManager.save_dashboard_template!(controller, "  ") == false
                @test PsychophysicsManager.save_dashboard_template!(controller, "a/b") == false
                @test PsychophysicsManager.save_dashboard_template!(controller, "Gabor") == false
                @test controller.message == ui_label(:msg_template_exists; name = "Gabor")
                @test PsychophysicsManager.save_dashboard_template!(controller, "Gabor copy")
                copy_ = load_session(joinpath(resolve_templates_dir(), "Gabor copy.json"))
                @test copy_.participant_id == DEFAULT_PARTICIPANT_ID && isempty(copy_.history)
                @test copy_.feedback && copy_.tags == ["pilot"]
                @test [row.name for row in PsychophysicsManager.dashboard_templates()] ==
                      ["Gabor", "Gabor copy"]

                # A previous session is opened with its data; one that ended is the
                # template of a new session, one not finished runs on in its own file
                PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test PsychophysicsManager.control_buttons(controller) == [:start_new]
                interrupted = create_replicated_session(template, "P09")
                start_session!(interrupted)
                interrupted.state = RUNNING
                path = save_session_checkpoint(interrupted, resolve_data_dir())
                previous = PsychophysicsManager.dashboard_previous_sessions()
                @test [row.participants for row in previous] == ["P09", "P08"]
                @test [row.continuable for row in previous] == [true, false]
                @test [row.participants for row in
                       PsychophysicsManager.dashboard_previous_sessions(; continuable_only = true)] == ["P09"]
                # The filter's choices are plain strings, which the window's lists take
                @test PsychophysicsManager.dashboard_session_participants(previous) == ["P08", "P09"]
                @test eltype(PsychophysicsManager.dashboard_session_participants(previous)) == String
                # A participant measured without a profile is offered again
                @test PsychophysicsManager.dashboard_participants(previous) ==
                      [DEFAULT_PARTICIPANT_ID, "P07", "P08", "P09"]
                @test [row.participants for row in
                       PsychophysicsManager.filter_session_rows(previous; participant = "P08")] == ["P08"]
                @test [row.participants for row in
                       PsychophysicsManager.filter_session_rows(previous; continuable_only = true)] == ["P09"]

                @test PsychophysicsManager.open_previous_session!(controller, previous[2].path)
                finished = controller.session
                @test finished.state == FINISHED && length(finished.history) == 6
                @test controller.participant == "P08"
                @test controller.message == ui_label(:msg_opened; file = basename(previous[2].path))
                PsychophysicsManager.set_dashboard_participant!(controller, "P10")
                @test finished.participant_id == "P08"   # what was measured stays
                # An edit prepares a new session, which another choice in Browse drops
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "tags", "retest")
                @test PsychophysicsManager.prepared_session(controller) !== nothing
                @test PsychophysicsManager.open_previous_session!(controller, previous[2].path)
                @test PsychophysicsManager.prepared_session(controller) === nothing
                finished = controller.session
                PsychophysicsManager.set_dashboard_participant!(controller, "P10")
                # Start New Session runs the session prepared, with its edits
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "tags", "retest")
                prepared = PsychophysicsManager.prepared_session(controller)
                @test prepared.participant_id == "P10" && finished.tags == ["pilot"]
                @test PsychophysicsManager.start_new_session!(controller)
                wait(controller.run_task)
                @test controller.session === prepared && prepared.tags == ["retest"]
                @test PsychophysicsManager.prepared_session(controller) === nothing
                @test controller.session !== finished && controller.session.participant_id == "P10"
                @test controller.session.state == FINISHED && finished.state == FINISHED

                # A run that broke off is opened paused, and Resume runs it on
                @test PsychophysicsManager.open_previous_session!(controller, path)
                @test controller.session.state == PAUSED
                @test PsychophysicsManager.control_buttons(controller) == [:resume, :stop]
                @test PsychophysicsManager.start_new_session!(controller) == false
                PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.id == interrupted.id
                @test controller.session.state == FINISHED
                @test length(controller.session.history) == 6
                @test PsychophysicsManager.open_previous_session!(controller, "nowhere.json") == false
                # The row of a session the dashboard runs is built from the session
                row = PsychophysicsManager.dashboard_entry_row(controller.session)
                @test row.path == controller.session.save_path && row.participants == "P09"
                @test row.trials == "6 / 6" && !row.continuable
                # A script's session that ended presents nothing more from the window
                attached = DashboardController(controller.session)
                @test isempty(PsychophysicsManager.control_buttons(attached))
            end
        end
    end

    @testset "Parameters are edited before a session starts" begin
        # What an operator types, read as a session file writes values, and written
        # back so that it reads as the same value
        @test PsychophysicsManager.parse_setting_text("") === nothing
        @test PsychophysicsManager.parse_setting_text(" 12 ") === 12
        @test PsychophysicsManager.parse_setting_text("0.25") === 0.25
        @test PsychophysicsManager.parse_setting_text("1, 2, 4") == [1, 2, 4]
        @test PsychophysicsManager.parse_setting_text("0:2") == [0, 1, 2]
        @test PsychophysicsManager.parse_setting_text("0:0.5:1.5") == [0.0, 0.5, 1.0, 1.5]
        @test PsychophysicsManager.parse_setting_text("0:2, 5") == [0, 1, 2, 5]
        @test PsychophysicsManager.parse_setting_text("middle") == "middle"
        @test PsychophysicsManager.parse_setting_text("yes") === true
        for value in (240.0, 0.012589254117941673, [0, 1, 2, 3], [0.1, 0.2, 0.3, 0.4],
                      collect(10 .^ range(-2.0, 0.0; length = 5)), (2, 30), [1, 2, 4])
            @test PsychophysicsManager.parse_setting_text(PsychophysicsManager.setting_edit_text(value)) == collect(value) ||
                  PsychophysicsManager.parse_setting_text(PsychophysicsManager.setting_edit_text(value)) == value
        end
        @test PsychophysicsManager.setting_edit_text(0:5) == "0:5"
        @test PsychophysicsManager.setting_edit_text([0.0, 0.5, 1.0]) == "0:0.5:1"

        session = SessionContext("E", ExperimentParameters("Edit", [:contrast, :target_interval],
                                                          Any[[0.1, 0.2], [1, 2]], 2),
                                 Gabor(), ConstantStimuli())
        session.engine_name = "EmulatorEngine"
        # The common path: a refusal changes nothing and names the parameter
        @test_throws ArgumentError set_parameters!(session, Dict("stim_par.nope" => 1))
        @test_throws ArgumentError set_parameters!(session, Dict("ex_par.repeats" => 0))
        @test_throws ArgumentError set_parameters!(session, Dict("ex_par.repeats" => 2.5))
        # A stimulus that cannot be presented is refused when set, at every level
        @test_throws ArgumentError set_parameters!(session, Dict("stim_par.mean_luminance" => 1.5))
        err = try
            set_parameters!(session, Dict("ex_par.indep_var_ranges" => Any[[0.1, 2.0], [1, 2]]))
        catch e
            e
        end
        @test err isa ArgumentError && occursin("Level 2.0 of contrast", err.msg)
        @test session.ex_par.indep_var_ranges[1] == [0.1, 0.2] && session.ex_par.repeats == 2
        # A design the stimulus cannot score is refused, the session's own as it is too
        unscorable = SessionContext("G", ExperimentParameters("G", :contrast, [0.1, 0.2], 1),
                                    Gabor(), ConstantStimuli())
        err = try set_parameters!(unscorable, Dict{String, Any}()) catch e e end
        @test err isa ArgumentError && occursin("target_interval", err.msg)
        @test isempty(set_parameters!(session, Dict{String, Any}()).history)
        set_parameters!(session, Dict("ex_par.repeats" => 3, "stim_par.sigma_px" => 10))
        @test session.ex_par.repeats == 3 && session.stim_par.sigma_px == 10.0

        # The dashboard edits the session in hand, prepared and not started
        controller = DashboardController(session; owns_engine = true)
        @test PsychophysicsManager.can_edit_parameters(controller)
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "levels.contrast", "0.1:0.1:0.4")
        @test session.ex_par.indep_var_ranges[1] == [0.1, 0.2, 0.3, 0.4]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.size_px", "96")
        @test session.stim_par.size_px == 96
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.experiment_name", "2026")
        @test session.ex_par.experiment_name == "2026"
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "tags", "pilot, , left eye")
        @test session.tags == ["pilot", "left eye"]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "feedback", "yes") && session.feedback
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "timeout_s", "2.5")
        @test session.timeout_s == 2.5
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "timeout_s", "")
        @test session.timeout_s === nothing
        # Refused, with the reason in the panel, and nothing changed
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.size_px", "big") == false
        @test startswith(controller.message, ui_label(:msg_parameter_refused; error = "")) &&
              session.stim_par.size_px == 96
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "levels.contrast", "") == false
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "levels.contrast", "low") == false
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "timeout_s", "-1") == false
        @test session.ex_par.indep_var_ranges[1] == [0.1, 0.2, 0.3, 0.4]

        # The method is chosen among those that can be built with no arguments, and
        # its settings are edited as the other parameters are
        @test issubset(["Adjustment", "ConstantStimuli", "Staircase"],
                       selectable_methods())
        @test !("Interleaved" in selectable_methods())
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method", "Staircase")
        @test session.method_instance isa Staircase
        rows = PsychophysicsManager.dashboard_setup_rows(session)
        @test [row.key for row in rows.experiment if row.key !== nothing &&
                                                     startswith(row.key, "method")] ==
              ["method", "method.n_down", "method.trial_limit", "method.levels"]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.n_down", "3")
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.trial_limit", "40")
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.levels", "0.1, 0.2")
        method = session.method_instance
        @test method.n_down == 3 && method.declared_trial_limit == 40 &&
              method.declared_levels == [0.1, 0.2]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.n_down", "0") == false
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.n_down", "two") == false
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.nope", "1") == false
        @test session.method_instance.n_down == 3
        # Adjustment adjusts the stimulus's first numeric parameter that is not a
        # variable and leaves its range to the operator: the session waits for it
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method", "Adjustment")
        @test session.method_instance.dep_var == :cycles_per_px
        @test unset_settings(session.method_instance) == [:dep_range]
        rows = PsychophysicsManager.dashboard_setup_rows(session)
        range_row = only(filter(row -> row.key == "method.dep_range", rows.experiment))
        @test range_row.unset && range_row.edit == ""
        @test !only(filter(row -> row.key == "method.dep_var", rows.experiment)).unset
        @test PsychophysicsManager.start_experiment!(controller) == false
        @test controller.message == ui_label(:msg_settings_unset; method = "Adjustment",
                                             settings = "dep_range")
        @test session.state == READY && session.save_path === nothing
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method.dep_range",
                                                             "0.01:0.01:0.1")
        @test isempty(unset_settings(session.method_instance))
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method", "Staircase")
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method", "NoSuchMethod") == false
        @test session.method_instance isa Staircase
        unscored = SessionContext("U", ExperimentParameters("U", :duration_ms, [100.0], 1),
                                  BaseStimulusParameters(100.0), ConstantStimuli())
        # A staircase steps on the answer's direction where there is no correct answer
        set_parameters!(unscored, Dict("method" => "Staircase"))
        @test unscored.method_instance isa Staircase
        # A stimulus with no number left to adjust leaves the dependent variable unset
        set_parameters!(unscored, Dict("method" => "Adjustment"))
        @test unset_settings(unscored.method_instance) == [:dep_var, :dep_range]
        dependent = only(filter(row -> row.key == "method.dep_var",
                                PsychophysicsManager.dashboard_setup_rows(unscored).experiment))
        @test dependent.unset && dependent.value == "" && isempty(dependent.choices)
        set_parameters!(unscored, Dict("method" => "Adjustment",
                                       "method.dep_var" => "duration_ms",
                                       "method.dep_range" => [50, 100, 150]))
        @test unscored.method_instance.dep_var == :duration_ms &&
              unscored.method_instance.dep_range == [50, 100, 150]
        # An adjustment's dependent variable is its adjusted parameter, listed with its
        # range and starting interval, and the answer measure and task type go
        adjusted = PsychophysicsManager.dashboard_setup_rows(unscored)
        dependent = only(filter(row -> row.key == "method.dep_var", adjusted.experiment))
        @test dependent.label == ui_label(:setup_dependent) && dependent.value == "duration_ms"
        @test ("duration_ms" => "duration_ms") in dependent.choices
        @test any(row -> row.key == "method.dep_range", adjusted.experiment)
        @test !any(row -> row.key == "task", adjusted.experiment)

        # Units: a conversion as its formula is written, read back
        mktempdir() do unit_dir
            cd(unit_dir) do
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.contrast",
                                                          "log10 contrast = log10(contrast)")
                @test session.unit_conversions[:contrast] ==
                      UnitConversion("log10 contrast"; form = :log10, formula = "log10(contrast)")
                units = only(filter(row -> row.key == "units.contrast",
                                    PsychophysicsManager.dashboard_setup_rows(session).experiment))
                @test PsychophysicsManager.parse_unit_conversion(:contrast, units.edit) ==
                      session.unit_conversions[:contrast]
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.contrast",
                                                          "% = x * x") == false
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.contrast", "")
                @test !haskey(session.unit_conversions, :contrast)
            end
        end
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "method", "ConstantStimuli")

        # The independent variables are stimulus parameters chosen from a list: one is
        # replaced, added and removed; a parameter made a variable starts at its value
        rows = PsychophysicsManager.dashboard_setup_rows(session)
        first_variable = only(filter(row -> row.key == "variable.1", rows.experiment))
        @test first_variable.value == "contrast" && ("orientation_deg" => "orientation_deg") in
              first_variable.choices
        @test "sigma_px" in last.(only(filter(row -> row.key == "variable.new",
                                              rows.experiment)).choices)
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.new", "orientation_deg")
        @test session.ex_par.indep_var_names == [:contrast, :target_interval, :orientation_deg]
        @test session.ex_par.indep_var_ranges[3] == [session.stim_par.orientation_deg]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "levels.orientation_deg", "0, 90")
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.3", "phase_deg")
        @test session.ex_par.indep_var_names[3] == :phase_deg
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.3", "")
        @test session.ex_par.indep_var_names == [:contrast, :target_interval]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.1", "target_interval") == false
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.new", "nope") == false
        one = SessionContext("O", ExperimentParameters("O", :contrast, [0.1], 1),
                             Gabor(), ConstantStimuli())
        @test_throws ArgumentError set_parameters!(one, PsychophysicsManager.edited_variables(
            one.ex_par, one.stim_par, "1", ""))
        # The task type decides where the curve starts
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "task", "0.5")
        @test session.fit_gamma == 0.5
        # A refusal names the line as Parameters shows it, and the next change taken
        # replaces it in the panel
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "abc") == false
        @test occursin("`$(ui_label(:setup_repeats))`", controller.message)
        @test !occursin("ex_par", controller.message)
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "3")
        @test controller.message == ui_label(:msg_parameter_changed; name = ui_label(:setup_repeats))

        # A session that has started is what it measured
        start_session!(session)
        @test !PsychophysicsManager.can_edit_parameters(controller)
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "5") == false
        @test controller.message == ui_label(:msg_parameters_fixed)
        @test_throws ArgumentError set_parameters!(session, Dict("ex_par.repeats" => 5))
        abort!(session)
        # Its units still change: they change what a report shows, not the record
        mktempdir() do unit_dir
            cd(unit_dir) do
                @test PsychophysicsManager.can_edit_reporting(controller)
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.contrast",
                                                          "Contrast (%) = 100 * contrast")
                @test session.unit_conversions[:contrast].scale == 100
                @test PsychophysicsManager.prepared_session(controller) === nothing
                # Any other edit goes to a new session prepared from it, the first edit taken
                # preparing it; the ended session stays in hand, as it was measured
                @test PsychophysicsManager.can_edit_parameters(controller)
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.new", "nope") == false
                @test PsychophysicsManager.prepared_session(controller) === nothing
                PsychophysicsManager.set_dashboard_participant!(controller, "P11")
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "task", "0")
                prepared = PsychophysicsManager.prepared_session(controller)
                @test prepared !== nothing && prepared !== session && prepared.state == READY
                @test controller.session === session && session.fit_gamma == 0.5
                @test prepared.fit_gamma == 0.0 && prepared.participant_id == "P11"
                @test prepared.unit_conversions[:contrast].scale == 100
                @test controller.message == ui_label(:msg_new_session_prepared; participant = "P11")
                @test PsychophysicsManager.parameters_session(controller) === prepared
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "5")
                @test PsychophysicsManager.prepared_session(controller) === prepared
                @test prepared.ex_par.repeats == 5 && session.ex_par.repeats == 3
                @test PsychophysicsManager.set_dashboard_parameters!(controller, Dict("ex_par.repeats" => 4))
                @test prepared.ex_par.repeats == 4 && session.ex_par.repeats == 3
                # The participant chosen and the units go to the prepared session too
                PsychophysicsManager.set_dashboard_participant!(controller, "P12")
                @test prepared.participant_id == "P12" && session.participant_id != "P12"
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.contrast", "")
                @test !haskey(prepared.unit_conversions, :contrast) &&
                      session.unit_conversions[:contrast].scale == 100
                @test PsychophysicsManager.control_buttons(controller) == [:start_new]
                # While a loop runs the session in hand, nothing is prepared or edited
                session.state = RUNNING
                @test PsychophysicsManager.prepared_session(controller) === nothing
                @test PsychophysicsManager.parameters_session(controller) === session
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "2") == false
                session.state = ABORTED
                @test PsychophysicsManager.prepared_session(controller) === prepared
            end
        end
    end

    @testset "Unit defaults in Parameters and dashboard editing" begin
        mktempdir() do dir
            user = joinpath(dir, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, "[rig]\nname = \"Booth 1\"\npixel_arcmin = 0.5\n")
            project = mkpath(joinpath(dir, "project"))
            project_file = joinpath(project, "settings.toml")
            withenv(PsychophysicsManager.USER_SETTINGS_VARIABLE => user) do
                cd(project) do
                    ex_par = ExperimentParameters("Units", :DistrN, [1, 3], 1)
                    method = Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0)
                    session = SessionContext("P1", ex_par, MarkerLayout(Ref = 20.0), method)
                    session.engine_name = "EmulatorEngine"
                    controller = DashboardController(session; owns_engine = true)

                    # Editing writes the entry into the project's settings.toml and sets the conversion
                    @test PsychophysicsManager.edit_dashboard_parameter!(
                        controller, "units.Diff", "Illusion (arcmin) = Diff * pixel_arcmin")
                    @test session.unit_conversions[:Diff].scale ≈ 0.5
                    @test session.unit_conversions[:Diff].formula == "Diff * pixel_arcmin"
                    @test isfile(project_file)
                    @test PsychophysicsManager.load_unit_defaults("MarkerLayout", project)[:Diff] ==
                          (text = "Illusion (arcmin) = Diff * pixel_arcmin", source = project_file)
                    # Settings view does not list [units]
                    @test !any(s -> startswith(s.name, "units"), PsychophysicsManager.dashboard_settings())

                    # Refused formula writes nothing and leaves the session unchanged
                    before_text = read(project_file, String)
                    @test PsychophysicsManager.edit_dashboard_parameter!(
                        controller, "units.Diff", "Bad = Diff * unknown_const") == false
                    @test read(project_file, String) == before_text
                    @test session.unit_conversions[:Diff].scale ≈ 0.5

                    # Empty text removes both the conversion and the settings entry
                    @test PsychophysicsManager.edit_dashboard_parameter!(controller, "units.Diff", "")
                    @test !haskey(session.unit_conversions, :Diff)
                    @test isempty(PsychophysicsManager.load_unit_defaults("MarkerLayout", project))

                    # READY session without conversion shows project default with source & tooltip
                    write(project_file, """
                    [units.MarkerLayout]
                    DistrN = "Number of distractors"
                    Diff   = "Illusion (arcmin) = Diff * pixel_arcmin"
                    """)
                    rows = PsychophysicsManager.dashboard_setup_rows(session).experiment
                    distr_row = only(filter(r -> r.key == "units.DistrN", rows))
                    diff_row = only(filter(r -> r.key == "units.Diff", rows))
                    @test distr_row.value == "Number of distractors"
                    @test distr_row.edit == "Number of distractors"
                    @test distr_row.source == project_file && !distr_row.unset
                    @test distr_row.tooltip == ui_label(:settings_from_file; path = project_file)
                    @test diff_row.value == "Illusion (arcmin)"
                    @test diff_row.edit == "Illusion (arcmin) = Diff * pixel_arcmin"
                    @test diff_row.source == project_file && !diff_row.unset
                    @test diff_row.tooltip == ui_label(:settings_from_file; path = project_file)

                    # An unparseable entry shows its text with unset = true and the reason in tooltip
                    write(project_file, """
                    [units.MarkerLayout]
                    Diff = "Illusion = Diff * missing_const"
                    """)
                    bad_row = only(filter(r -> r.key == "units.Diff",
                                          PsychophysicsManager.dashboard_setup_rows(session).experiment))
                    @test bad_row.value == "Illusion = Diff * missing_const"
                    @test bad_row.edit == "Illusion = Diff * missing_const"
                    @test bad_row.source == project_file && bad_row.unset
                    @test occursin("missing_const", bad_row.tooltip)
                    # Start is refused cleanly before any file is written
                    @test PsychophysicsManager.start_experiment!(controller) == false
                    @test occursin("missing_const", controller.message)
                    @test session.state == READY && session.save_path === nothing

                    # A refused write (invalid settings.toml) leaves the session unchanged
                    write(project_file, "[units.MarkerLayout]\nDiff = \n")
                    @test PsychophysicsManager.edit_dashboard_parameter!(
                        controller, "units.Diff", "Illusion = Diff * pixel_arcmin") == false
                    @test !haskey(session.unit_conversions, :Diff)

                    # Started/finished session uses its recorded session.rig, not current load_rig()
                    write(project_file, "[storage]\ndata_dir = \"data\"\n")
                    start_session!(session)
                    @test session.rig["pixel_arcmin"] == 0.5
                    abort!(session)
                    write(user, "[rig]\nname = \"Booth 2\"\npixel_arcmin = 1.25\n")
                    @test PsychophysicsManager.edit_dashboard_parameter!(
                        controller, "units.Diff", "Illusion = Diff * pixel_arcmin")
                    @test session.unit_conversions[:Diff].scale ≈ 0.5
                end
            end
        end
    end

    @testset "Participant messages in the dashboard" begin
        # 1. dashboard_setup_rows(session).messages has the seven rows with the keys; with no task the instructions row has no key
        session = make_session()
        rows = PsychophysicsManager.dashboard_setup_rows(session)
        @test haskey(rows, :messages)
        msgs = rows.messages
        @test length(msgs) == 7
        @test msgs[1].key === nothing
        @test msgs[1].label == ui_label(:setup_instructions)
        @test msgs[1].value == ui_label(:setup_no_task)
        @test msgs[2].key == "messages.break_every"
        @test msgs[2].label == ui_label(:setup_break_every)
        @test msgs[2].value == ui_label(:setup_no_breaks)
        @test msgs[2].edit == ""
        @test msgs[3].key == "messages.break_after"
        @test msgs[3].label == ui_label(:setup_break_after)
        @test msgs[3].value == "—"
        @test msgs[3].edit == ""
        @test msgs[4].key == "messages.break_waits_for"
        @test msgs[4].label == ui_label(:setup_break_waits_for)
        @test msgs[4].value == ui_label(:waits_for_participant)
        @test msgs[4].choices == [ui_label(:waits_for_participant) => "participant",
                                 ui_label(:waits_for_operator) => "operator"]
        @test msgs[5].key == "messages.break_min_s"
        @test msgs[5].label == ui_label(:setup_break_min)
        @test msgs[5].value == ui_label(:setup_seconds; seconds = "0")
        @test msgs[5].edit == "0"
        @test msgs[6].key == "messages.break_text"
        @test msgs[6].label == ui_label(:setup_break_text)
        @test msgs[6].value == ""
        @test msgs[6].edit == ""
        @test msgs[7].key == "messages.closing_text"
        @test msgs[7].label == ui_label(:setup_closing_text)
        @test msgs[7].value == "—"
        @test msgs[7].edit == ""

        # With a task set, instructions row has key "messages.instructions"
        set_task!(session, length_comparison_task())
        msgs_with_task = PsychophysicsManager.dashboard_setup_rows(session).messages
        @test msgs_with_task[1].key == "messages.instructions"
        @test msgs_with_task[1].label == ui_label(:setup_instructions)
        @test msgs_with_task[1].value == ui_label(:no)
        @test msgs_with_task[1].edit == "no"

        # 2. edit_dashboard_parameter!
        controller = DashboardController(session; owns_engine = true)
        # break_every with empty break_text is refused
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_every", "5") == false
        @test occursin("break_text", controller.message)

        # break_every with non-integer is refused
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_every", "x") == false
        @test occursin("Breaks come after every n trials", controller.message)

        # Now set the fields properly
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_text", "Rest")
        @test session.messages.break_text == "Rest"
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.closing_text", "Thanks")
        @test session.messages.closing_text == "Thanks"
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_every", "20")
        @test session.messages.break_every == 20
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_after", "5, 10")
        @test session.messages.break_after == [5, 10]
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_waits_for", "operator")
        @test session.messages.break_waits_for === :operator
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.break_min_s", "30")
        @test session.messages.break_min_s == 30.0
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "messages.instructions", "yes")
        @test session.messages.instructions == true

        # 3. end_dashboard_message!
        @test session.shown_message === nothing
        @test PsychophysicsManager.end_dashboard_message!(controller) == false
        @test controller.message == ui_label(:msg_no_message_shown)

        session.shown_message = ParticipantMessage(:instructions, "Read carefully", true, 0.0, () -> true)
        @test PsychophysicsManager.end_dashboard_message!(controller) == true
        @test session.shown_message === nothing
        @test controller.message == ui_label(:msg_message_ended)

        # 4. keyboard_control returns nothing while session.shown_message !== nothing
        @test session.state == READY
        @test PsychophysicsManager.action_state(controller).can_start
        @test PsychophysicsManager.keyboard_control(controller) === :start

        session.shown_message = ParticipantMessage(:instructions, "Read carefully", true, 0.0, () -> true)
        @test PsychophysicsManager.keyboard_control(controller) === nothing
        session.shown_message = nothing
        @test PsychophysicsManager.keyboard_control(controller) === :start
        @test PsychophysicsManager.action_state(controller).can_start == true

        # 5. A dashboard-run session with messages
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext(ExperimentParameters("MsgTest", :level, [1.0, 2.0], 1),
                                          BaseStimulusParameters(100.0), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                set_task!(template, length_comparison_task())
                set_messages!(template; instructions = true)
                setup = save_session_checkpoint(template, resolve_templates_dir();
                                                filename = "MsgTest.json")
                ch = Channel{Tuple{Int, Float64}}(1)
                source = PsychophysicsManager.ChannelResponseSource(ch)
                run_controller = DashboardController()
                PsychophysicsManager.install_response_source!(run_controller, source)
                try
                    @test PsychophysicsManager.choose_setup!(run_controller, setup)
                    @test PsychophysicsManager.start_experiment!(run_controller)
                    @test timedwait(() -> PsychophysicsManager.shown_message(source) !== nothing, 5.0) == :ok
                    msg = PsychophysicsManager.shown_message(source)
                    @test msg !== nothing && msg.kind === :instructions
                    @test run_controller.session.shown_message === msg

                    # While instructions message is shown, keyboard_control returns nothing
                    @test PsychophysicsManager.keyboard_control(run_controller) === nothing

                    # Key offered to channel dismisses instructions
                    @test PsychophysicsManager.offer_response!(ch, 0)
                    @test timedwait(() -> PsychophysicsManager.shown_message(source) === nothing, 5.0) == :ok

                    # Feed responses for the 2 trials
                    while !istaskdone(run_controller.run_task)
                        PsychophysicsManager.offer_response!(ch, 1)
                        sleep(0.05)
                    end
                    @test run_controller.session.state == FINISHED
                    @test length(run_controller.session.history) == 2
                finally
                    PsychophysicsManager.close_controller!(run_controller)
                end
            end
        end
    end

    @testset "A worker's own stimulus is edited as any other" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext("T", ExperimentParameters("OK", :DistrN, [1, 3], 2),
                                          WorkerStimulus("oppel_kundt"; Ref = 100,
                                                         DistrN = 3, StimConfig = "r d t",
                                                         Mirror = false),
                                          ConstantStimuli())
                template.engine_name = "RemoteEngine"
                path = save_session_checkpoint(template, resolve_templates_dir();
                                               filename = "Declared.json")
                # Listed by the name the worker declares, and nothing reported obsolete
                @test only(PsychophysicsManager.dashboard_templates()).stimulus == "oppel_kundt"
                @test isempty(PsychophysicsManager.obsolete_stimulus_fields(
                    PsychophysicsManager.read_json_document(path)))

                controller = DashboardController(; owns_engine = true)
                @test PsychophysicsManager.choose_setup!(controller, path)
                session = controller.session
                setup = PsychophysicsManager.dashboard_setup_rows(session)
                @test [row.label for row in setup.stimulus] ==
                      ["Ref", "DistrN", "StimConfig", "Mirror"]
                @test only(filter(row -> row.label == "DistrN", setup.stimulus)).value ==
                      ui_label(:set_by_design)
                @test (ui_label(:setup_stimulus) => "oppel_kundt") in
                      [row.label => row.value for row in setup.experiment]
                # A variable is made of a parameter that holds a number
                added = only(filter(row -> row.key == "variable.new", setup.experiment))
                @test [choice.second for choice in added.choices] == ["Ref"]

                # A value is taken in the kind the parameter holds, and text as typed
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.Ref", "120.5")
                @test parameter_value(session.stim_par, :Ref) == 120.5
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.StimConfig", "r t")
                @test parameter_value(session.stim_par, :StimConfig) == "r t"
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.Mirror", "yes")
                @test parameter_value(session.stim_par, :Mirror) === true
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stim_par.Ref", "far") ==
                      false
                @test occursin("number", controller.message)
                @test parameter_value(session.stim_par, :Ref) == 120.5
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "variable.new", "Ref")
                @test session.ex_par.indep_var_names == [:DistrN, :Ref]
                @test session.ex_par.indep_var_ranges[2] == [120.5]
            end
        end
    end

    @testset "Browse by series, filters, and combining checks" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\n\n[combining]\nfeedback = false\n")
                function saved(participant, start; experiment = "Oppel",
                               stim = MarkerLayout(Ref = 10.0),
                               method = ConstantStimuli(),
                               ex_par = ExperimentParameters(experiment, :Diff, [-5.0, 5.0], 1),
                               tags = String[], state = FINISHED,
                               trials = 2, invalid = 0, comments = String[])
                    s = SessionContext(participant, ex_par, stim, method; tags = copy(tags))
                    s.engine_name = "EmulatorEngine"
                    s.start_time = start
                    s.state = state
                    for i in 1:trials
                        push!(s.history, Trial(i, start, start + 0.5, [1.0], 1, i > invalid))
                    end
                    for note in comments
                        add_comment!(s, note)
                    end
                    return s, save_session_checkpoint(s, resolve_data_dir())
                end

                t1 = datetime2unix(DateTime(2026, 5, 10, 9, 0, 0))
                t2 = datetime2unix(DateTime(2026, 5, 10, 15, 0, 0))
                t3 = datetime2unix(DateTime(2026, 5, 11, 10, 0, 0))
                t4 = datetime2unix(DateTime(2026, 5, 12, 8, 0, 0))

                s1, p1 = saved("P1", t1; stim = MarkerLayout(Ref = 10.0),
                               tags = ["pilot"], state = FINISHED, trials = 3, invalid = 1)
                s2, p2 = saved("P1", t3; stim = MarkerLayout(Ref = 10.0),
                               tags = ["pilot", "extra"], state = PAUSED, trials = 1)
                _, p3 = saved("P1", t2; stim = MarkerLayout(Ref = 20.0),
                              tags = ["main"], state = FINISHED, trials = 2,
                              comments = ["bright"])
                _, p4 = saved("P2", t4; experiment = "Contrast",
                              stim = Gabor(sigma_px = 12.0), method = Staircase(),
                              ex_par = ExperimentParameters("Contrast", [:contrast, :target_interval],
                                                            Any[[0.1, 0.2], [1, 2]], 1),
                              tags = ["main"], state = FINISHED, trials = 4)
                set_path = save_analysis_set(AnalysisSet([s1, s2]; checks = Symbol[]),
                                             joinpath(resolve_data_dir(), "pooled.json"))

                # Combining checks start from settings.toml
                controller = DashboardController(; owns_engine = true)
                @test controller.checks == [:instructions, :observer, :timeout, :stimulus]

                entries = PsychophysicsManager.reread_library!(controller)
                series = PsychophysicsManager.dashboard_series_rows(
                    entries, PsychophysicsManager.DashboardFilters(), controller.checks)
                @test length(series) == 3

                # Ordered newest last run first: Contrast (t4), Oppel Ref=10 (t3), Oppel Ref=20 (t2)
                @test [(s.participant, s.experiment) for s in series] ==
                      [("P2", "Contrast"), ("P1", "Oppel"), ("P1", "Oppel")]
                @test series[1].variables == ""
                # Sessions saved without a drawn plan count their valid trials only
                @test series[1].repetitions == 1 && series[1].trials == "4"
                @test !series[1].continuable

                @test series[2].variables == "Ref = 10"
                @test series[2].repetitions == 2 && series[2].trials == "3"
                @test series[2].continuable
                @test series[2].key == abspath(p1)
                @test [r.path for r in series[2].sessions] == abspath.([p1, p2])

                @test series[3].variables == "Ref = 20"
                @test series[3].repetitions == 1 && series[3].trials == "2"
                @test !series[3].continuable

                # Combined datasets are returned separately from series
                datasets = PsychophysicsManager.dashboard_dataset_rows(entries)
                @test length(datasets) == 1
                @test datasets[1].path == abspath(set_path) && datasets[1].dataset

                # Filters narrow series in memory
                F = PsychophysicsManager.DashboardFilters
                by(filters) = PsychophysicsManager.dashboard_series_rows(entries, filters,
                                                                         controller.checks)
                @test [s.participant for s in by(F(participant = "P2"))] == ["P2"]
                @test length(by(F(experiment = "Oppel"))) == 2
                @test [s.variables for s in by(F(tags = "pilot"))] == [""]
                @test only(by(F(tags = "pilot"))).repetitions == 2
                @test [s.key for s in by(F(state = :continuable))] == [abspath(p2)]
                @test length(by(F(state = FINISHED))) == 3
                @test only(by(F(state = FINISHED, experiment = "Oppel",
                                parameter = "Ref = 10"))).repetitions == 1
                @test [s.key for s in by(F(text = "BRIGHT"))] == [abspath(p3)]
                @test [s.key for s in by(F(from = "2026-05-11", to = "2026-05-11"))] ==
                      [abspath(p2)]
                @test [s.experiment for s in by(F(method = "Staircase", stimulus = "Gabor"))] ==
                      ["Contrast"]
                # Malformed date or parameter text is ignored (and reported invalid for the view)
                @test !last(PsychophysicsManager.parse_filter_date("2026-05"))
                @test !last(PsychophysicsManager.parse_filter_date("not-a-date"))
                @test last(PsychophysicsManager.parse_filter_date("2026-05-11"))
                @test length(by(F(from = "not-a-date", to = "bad"))) == 3
                @test !last(PsychophysicsManager.parse_filter_parameter("Ref"))

                # Switching :stimulus check off merges the two Oppel series without touching settings.toml
                PsychophysicsManager.set_combining_check!(controller, :stimulus, false)
                merged = PsychophysicsManager.dashboard_series_rows(entries, F(), controller.checks)
                @test length(merged) == 2
                oppel_merged = only(filter(s -> s.experiment == "Oppel", merged))
                @test oppel_merged.repetitions == 3
                @test oppel_merged.trials == "5"
                @test load_combining_checks() == [:instructions, :observer, :timeout, :stimulus]
                @test_throws ArgumentError PsychophysicsManager.set_combining_check!(
                    controller, :method, false)
            end
        end
    end

    @testset "Ticks and choose_series!" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                function saved(start; state = FINISHED)
                    s = SessionContext("P1", ExperimentParameters("Rep", :level, [1.0, 2.0], 1),
                                       BaseStimulusParameters(100.0), ConstantStimuli())
                    s.engine_name = "EmulatorEngine"
                    s.start_time = start
                    s.state = state
                    push!(s.history, Trial(1, start, start + 0.5, [1.0], 1, true))
                    return save_session_checkpoint(s, resolve_data_dir())
                end
                p1 = saved(1.0e9)
                p2 = saved(2.0e9)

                controller = DashboardController(; owns_engine = true)
                entries = PsychophysicsManager.reread_library!(controller)
                row = only(PsychophysicsManager.dashboard_series_rows(entries))

                @test PsychophysicsManager.series_tick_state(row, controller.ticked) === :none
                PsychophysicsManager.tick_series!(controller, row, true)
                @test controller.ticked == abspath.([p1, p2])
                @test PsychophysicsManager.series_tick_state(row, controller.ticked) === :all

                PsychophysicsManager.tick_session!(controller, abspath(p1), false)
                @test PsychophysicsManager.series_tick_state(row, controller.ticked) === :some
                PsychophysicsManager.tick_series!(controller, row, false)
                @test isempty(controller.ticked)
                @test PsychophysicsManager.series_tick_state(row, controller.ticked) === :none

                # Removing a file and rereading drops its path from ticked
                PsychophysicsManager.tick_series!(controller, row, true)
                rm(p1)
                PsychophysicsManager.reread_library!(controller)
                @test controller.ticked == [abspath(p2)]
                PsychophysicsManager.clear_ticks!(controller)
                @test isempty(controller.ticked)

                # choose_series! opens the latest session of the series
                p3 = saved(3.0e9; state = PAUSED)
                entries2 = PsychophysicsManager.reread_library!(controller)
                row2 = only(PsychophysicsManager.dashboard_series_rows(entries2))
                @test PsychophysicsManager.choose_series!(controller, row2)
                @test controller.session.save_path == abspath(p3)
                @test controller.chosen == abspath(p3)
                @test controller.session.state == PAUSED
            end
        end
    end

    @testset "Parameters over several ticked sessions and relabelling" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                function saved(participant, start; experiment = "ExpA",
                               stim = MarkerLayout(Ref = 10.0, Color = :white),
                               ex_par = ExperimentParameters(experiment, :Diff, [-5.0, 5.0], 1),
                               tags = String[], state = FINISHED)
                    s = SessionContext(participant, ex_par, stim, ConstantStimuli();
                                       tags = copy(tags))
                    s.engine_name = "EmulatorEngine"
                    s.start_time = start
                    s.state = state
                    return save_session_checkpoint(s, resolve_data_dir())
                end

                p1 = saved("P1", 1.0e9; stim = MarkerLayout(Ref = 10.0, Color = :white),
                           tags = ["shared", "only1"])
                p2 = saved("P2", 2.0e9; stim = MarkerLayout(Ref = 20.0, Color = :white),
                           tags = ["shared", "only2"])
                p3 = saved("P3", 3.0e9; experiment = "ExpB",
                           stim = Gabor(sigma_px = 12.5),
                           ex_par = ExperimentParameters("ExpB", [:contrast, :target_interval],
                                                         Any[[0.1, 0.2], [1, 2]], 1),
                           tags = ["other"])
                p_paused = saved("P4", 4.0e9; state = PAUSED, tags = ["shared"])

                entries = browse_sessions(resolve_data_dir())
                entry_for(path) = only(filter(e -> e.path == abspath(path), entries))
                row_by_label(rows, label) = only(filter(r -> r.label == label, rows))

                # Two sessions sharing stimulus type, differing in Ref and tags
                rows12 = PsychophysicsManager.ticked_parameter_rows([entry_for(p1), entry_for(p2)])
                @test row_by_label(rows12, ui_label(:ticked_sessions)).value == "2"
                @test row_by_label(rows12, ui_label(:column_participants)).value == "P1, P2"
                exp_row = row_by_label(rows12, ui_label(:setup_experiment))
                @test exp_row.value == "ExpA" && exp_row.key == "experiment_name" && !exp_row.differs
                color_row = row_by_label(rows12, "Color")
                @test color_row.value == "white" && !color_row.differs && color_row.key === nothing
                ref_row = row_by_label(rows12, "Ref")
                @test ref_row.differs && ref_row.key === nothing
                @test occursin("10", ref_row.tooltip) && occursin("20", ref_row.tooltip)
                tags_row = row_by_label(rows12, ui_label(:setup_tags))
                @test tags_row.key == "tags" && tags_row.edit == "shared" && tags_row.differs
                comment_row = row_by_label(rows12, ui_label(:ticked_comment))
                @test comment_row.key == "comment" && comment_row.value == ""

                # Parameter absent from one session is marked with "—" in tooltip
                rows13 = PsychophysicsManager.ticked_parameter_rows([entry_for(p1), entry_for(p3)])
                sigma_row = row_by_label(rows13, "sigma_px")
                @test sigma_row.differs
                @test occursin("12.5", sigma_row.tooltip) && occursin("—", sigma_row.tooltip)
                ref_row13 = row_by_label(rows13, "Ref")
                @test ref_row13.differs
                @test occursin("10", ref_row13.tooltip) && occursin("—", ref_row13.tooltip)
                exp_row13 = row_by_label(rows13, ui_label(:setup_experiment))
                @test exp_row13.differs && exp_row13.edit == ""
                @test occursin("ExpA", exp_row13.tooltip) && occursin("ExpB", exp_row13.tooltip)

                # Relabelling through the controller updates files, marks lists stale, and reopens ended session
                controller = DashboardController(; owns_engine = true)
                @test PsychophysicsManager.open_previous_session!(controller, p1)
                PsychophysicsManager.tick_session!(controller, abspath(p1), true)
                PsychophysicsManager.tick_session!(controller, abspath(p2), true)

                controller.lists_stale = false
                @test !PsychophysicsManager.edit_ticked_labels!(controller, "experiment_name", "  ")
                @test !controller.lists_stale
                @test PsychophysicsManager.edit_ticked_labels!(controller, "experiment_name", "Renamed")
                @test controller.lists_stale
                @test load_session(p1).ex_par.experiment_name == "Renamed"
                @test load_session(p2).ex_par.experiment_name == "Renamed"
                @test controller.session.ex_par.experiment_name == "Renamed"

                # Tags: add "verified", remove shared "shared", leave "only1" and "only2" untouched
                controller.lists_stale = false
                @test PsychophysicsManager.edit_ticked_labels!(controller, "tags", "verified")
                @test controller.lists_stale
                @test load_session(p1).tags == ["only1", "verified"]
                @test load_session(p2).tags == ["only2", "verified"]
                @test controller.session.tags == ["only1", "verified"]

                # Comment added to all ticked sessions; empty comment refused
                controller.lists_stale = false
                @test !PsychophysicsManager.edit_ticked_labels!(controller, "comment", "   ")
                @test PsychophysicsManager.edit_ticked_labels!(controller, "comment", "QC passed")
                @test controller.lists_stale
                @test any(c -> c.text == "QC passed", load_session(p1).comments)
                @test any(c -> c.text == "QC passed", load_session(p2).comments)
                @test any(c -> c.text == "QC passed", controller.session.comments)

                # A ticked file of an unfinished session in hand is refused
                @test PsychophysicsManager.open_previous_session!(controller, p_paused)
                PsychophysicsManager.clear_ticks!(controller)
                PsychophysicsManager.tick_session!(controller, abspath(p_paused), true)
                PsychophysicsManager.tick_session!(controller, abspath(p2), true)
                controller.lists_stale = false
                @test !PsychophysicsManager.edit_ticked_labels!(controller, "experiment_name", "Blocked")
                @test !controller.lists_stale
                @test occursin(basename(p_paused), controller.message)
                @test load_session(p_paused).ex_par.experiment_name == "ExpA"
                @test load_session(p2).ex_par.experiment_name == "Renamed"
            end
        end
    end

    @testset "Saving ticked sessions as a combined dataset" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                function saved(participant, start; method = ConstantStimuli())
                    s = SessionContext(participant,
                                       ExperimentParameters("Pool", :level, [1.0, 2.0], 1),
                                       BaseStimulusParameters(100.0), method)
                    s.engine_name = "EmulatorEngine"
                    s.start_time = start
                    s.state = FINISHED
                    push!(s.history, Trial(1, start, start + 1, [1.0], 1, true))
                    return save_session_checkpoint(s, resolve_data_dir())
                end
                name(path) = first(splitext(basename(path)))

                p1 = saved("P1", 1.0e9)
                p2 = saved("P2", 2.0e9)
                p_incompat = saved("P3", 3.0e9; method = Staircase(2))

                controller = DashboardController(; owns_engine = true)
                # Nothing ticked refused
                @test !PsychophysicsManager.save_ticked_dataset!(controller, "Pooled")
                @test controller.message == ui_label(:msg_dataset_none_ticked)

                for path in (p1, p2, p_incompat)
                    PsychophysicsManager.tick_session!(controller, abspath(path), true)
                end

                # Empty, invalid, and existing names refused
                @test !PsychophysicsManager.save_ticked_dataset!(controller, "  ")
                @test controller.message == ui_label(:msg_dataset_name)
                @test !PsychophysicsManager.save_ticked_dataset!(controller, "a/b")
                @test controller.message == ui_label(:msg_dataset_name)
                @test !PsychophysicsManager.save_ticked_dataset!(controller, name(p1))
                @test occursin(basename(p1), controller.message)

                # Three ticked, one incompatible: file holds two, message names the one left out
                controller.lists_stale = false
                @test PsychophysicsManager.save_ticked_dataset!(controller, "Pooled")
                @test controller.lists_stale
                pooled = joinpath(resolve_data_dir(), "Pooled.json")
                set = load_analysis_set(pooled)
                @test [m.participant_id for m in set.sessions] == ["P1", "P2"]
                @test occursin("Pooled.json", controller.message)
                @test occursin(name(p_incompat), controller.message)
                @test occursin(ui_label(:fact_method), controller.message)

                # Existing dataset name refused
                @test !PsychophysicsManager.save_ticked_dataset!(controller, "Pooled")
                @test occursin("Pooled.json", controller.message)
            end
        end
    end

    @testset "A stimulus is previewed without a session running" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                session = SessionContext("P", ExperimentParameters("Preview",
                                         [:contrast, :target_interval], Any[[0.1, 0.4], [1, 2]], 1),
                                         Gabor(), ConstantStimuli())
                session.engine_name = "EmulatorEngine"
                # The grey lines hold the design's first levels
                rows = PsychophysicsManager.dashboard_setup_rows(session).stimulus
                contrast = only(filter(row -> row.label == "contrast", rows))
                @test contrast.key == "preview.contrast" && contrast.edit == "0.1"
                @test contrast.value == ui_label(:set_by_design)

                stimulus, vals = PsychophysicsManager.preview_condition(session, Dict{String, String}())
                @test vals == [0.1, 1.0] && stimulus.contrast == 0.1 && stimulus.target_interval == 1
                stimulus, vals = PsychophysicsManager.preview_condition(session,
                                     Dict("contrast" => "0.25", "target_interval" => "2"))
                @test vals == [0.25, 2.0] && stimulus.contrast == 0.25
                @test session.stim_par.contrast == Gabor().contrast   # untouched
                @test_throws ArgumentError PsychophysicsManager.preview_condition(session, Dict("contrast" => "high"))
                @test_throws ArgumentError PsychophysicsManager.preview_condition(session, Dict("contrast" => "2"))

                # The dashboard previews on an engine it keeps open until a session starts
                controller = DashboardController(session; owns_engine = true)
                @test PsychophysicsManager.can_preview(controller)
                @test PsychophysicsManager.preview_dashboard_stimulus!(controller, Dict("contrast" => "0.3"))
                wait(controller.preview_task)
                @test controller.message == ui_label(:msg_previewed)
                @test controller.preview_engine isa EmulatorEngine
                @test isempty(session.history) && session.save_path === nothing
                @test PsychophysicsManager.preview_dashboard_stimulus!(controller, Dict("contrast" => "x")) == false
                @test startswith(controller.message, ui_label(:msg_preview_refused; error = ""))
                PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test controller.preview_engine === nothing
                @test session.state == FINISHED
            end
        end
    end

    @testset "A preview's window closes, and the next preview opens another" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                session = SessionContext("P", ExperimentParameters("Preview", :contrast,
                                         [0.1, 0.4], 1), Gabor(), ConstantStimuli())
                session.engine_name = "PreviewWindowEngine"
                controller = DashboardController(session; owns_engine = true)
                @test !PsychophysicsManager.preview_open(controller)
                PsychophysicsManager.preview_dashboard_stimulus!(controller, Dict{String, String}())
                wait(controller.preview_task)
                first_engine = controller.preview_engine
                @test PsychophysicsManager.preview_open(controller)
                # Closed in the window itself, as Esc closes it
                first_engine.open = false
                @test !PsychophysicsManager.preview_open(controller)
                PsychophysicsManager.preview_dashboard_stimulus!(controller, Dict{String, String}())
                wait(controller.preview_task)
                @test controller.preview_engine !== first_engine
                @test PsychophysicsManager.preview_open(controller)
                # Closed from the dashboard
                second_engine = controller.preview_engine
                PsychophysicsManager.close_preview!(controller)
                @test !second_engine.open && !PsychophysicsManager.preview_open(controller)
            end
        end
    end

    @testset "A template parameter the stimulus no longer has is reported" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext("T", ExperimentParameters("Old",
                                              [:contrast, :target_interval], Any[[0.1], [1, 2]], 1),
                                          Gabor(), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                path = save_session_checkpoint(template, resolve_templates_dir(); filename = "old.json")
                document = PsychophysicsManager.read_json_document(path)
                document["stim_par"]["fields"]["blur_px"] = 3
                write(path, PsychophysicsManager.JSON3.write(document))
                @test PsychophysicsManager.obsolete_stimulus_fields(PsychophysicsManager.read_json_document(path)) ==
                      ["blur_px" => 3]
                @test_logs (:warn, r"blur_px = 3") load_session(path)
                controller = DashboardController()
                @test PsychophysicsManager.choose_setup!(controller, path)
                @test occursin("blur_px = 3", controller.message)
                @test occursin("Gabor", controller.message)
            end
        end
    end

    @testset "Loading and running a replication" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                source = SessionContext(
                    "Template",
                    ExperimentParameters("DashboardRun", :duration_ms, [20.0], 1),
                    BaseStimulusParameters(20.0),
                    ConstantStimuli(),
                )
                source.engine_name = "EmulatorEngine"
                source_path = save_session_checkpoint(source, dir; filename = "source.json")

                controller = DashboardController()
                @test controller.owns_engine

                # Refusals report why, and leave no session bound
                @test PsychophysicsManager.load_replication!(controller, "", "Bob") == false
                @test occursin("path", controller.message)
                @test PsychophysicsManager.load_replication!(controller, source_path, "  ") == false
                @test occursin("participant", lowercase(controller.message))
                @test PsychophysicsManager.load_replication!(controller, "no_such_file.json", "Bob") == false
                @test occursin("Could not load session", controller.message)
                @test controller.session === nothing

                @test PsychophysicsManager.load_replication!(controller, source_path, "Bob")
                @test controller.session !== nothing
                @test controller.session.participant_id == "Bob"
                @test controller.session.state == READY
                @test occursin("ready to start", controller.message)

                # The owning dashboard restores the engine and runs the loop
                # itself, then closes the engine
                @test PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test length(controller.session.history) == 1
                @test controller.engine === nothing
                @test controller.message == "Session finished."

                # A finished session cannot be restarted, and a new file can be
                # loaded again now that the run task is done
                @test PsychophysicsManager.start_experiment!(controller) == false
                @test PsychophysicsManager.action_state(controller).can_load

                # Undoing its last trial reopens it with no loop to run it: it waits
                # paused, and Resume runs the loop again to present the trial anew
                @test PsychophysicsManager.undo_dashboard_trial!(controller)
                @test controller.session.state == PAUSED
                @test occursin("Resume", controller.message)
                @test PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test count(t -> t.is_valid, controller.session.history) == 1
                @test length(controller.session.history) == 2

                # ...and a condition asked for after its end reopens it, and the
                # dashboard runs the loop again to present it
                @test PsychophysicsManager.present_dashboard_condition!(controller, [20.0])
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test length(controller.session.history) == 3
                @test controller.session.history[3].origin === :operator
                @test controller.engine === nothing

                # A session its loop left paused — an error, Ctrl+C — has no loop
                # to resume it: Resume runs the loop again, which continues it
                @test PsychophysicsManager.load_replication!(controller, source_path, "Carol")
                start_session!(controller.session)
                pause!(controller.session)
                @test PsychophysicsManager.action_state(controller).can_resume
                PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test length(controller.session.history) == 1
                @test controller.message == "Session finished."
            end
        end
    end

    @testset "A scenario plan runs from Browse" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml",
                      "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                setups = resolve_templates_dir()
                runs_dir = normpath(joinpath(setups, "..", "runs"))
                template = SessionContext("Template",
                    ExperimentParameters("Plan", :level, [1.0, 2.0], 1),
                    BaseStimulusParameters(100.0), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                save_session_checkpoint(template, setups; filename = "base.json")
                plan = joinpath(setups, "Two runs.toml")
                write(plan, """
                    [[run]]
                    id = "first"
                    source = "base.json"
                    destination = "../runs/first.json"
                    participant_id = "P01"

                    [[run]]
                    id = "second"
                    source = "base.json"
                    destination = "../runs/second.json"
                    participant_id = "P02"

                    [run.overrides]
                    ex_par.repeats = 2
                    """)
                write(joinpath(setups, "Broken.toml"), "title = \"no runs\"\n")
                states() = [entry.second for entry in scenario_run_states(plan)]

                # The plans of the templates directory, each with how far it has come
                plans = PsychophysicsManager.dashboard_plans()
                @test [row.name for row in plans] == ["Broken", "Two runs"]
                @test plans[1].problem && plans[1].next == ui_label(:plan_unreadable)
                @test plans[2].runs == "0 / 2" && plans[2].next == "first"
                @test [(row.id, row.participant, row.setup, row.file, row.state)
                       for row in PsychophysicsManager.dashboard_plan_runs(plan)] ==
                      [("first", "P01", "base", "first.json", ui_label(:run_to_run)),
                       ("second", "P02", "base", "second.json", ui_label(:run_to_run))]

                # A plan that cannot be run says why, and leaves nothing in hand
                controller = DashboardController()
                @test PsychophysicsManager.choose_scenario!(controller, plans[1].path) == false
                @test controller.session === nothing && controller.plan == plans[1].path
                @test startswith(controller.message, ui_label(:msg_plan_refused; error = ""))

                # Choosing a plan prepares its next run, for the participant it names; the
                # parameters can still be changed, and nothing is written before Start
                @test PsychophysicsManager.choose_scenario!(controller, plan)
                first_run = controller.session
                @test first_run.state == READY && first_run.participant_id == "P01"
                @test controller.plan == plans[2].path && controller.plan_run.row.id == "first"
                @test controller.message == ui_label(:msg_run_prepared; position = 1,
                    total = 2, plan = "Two runs", run = "first", participant = "P01",
                    file = "first.json")
                @test !PsychophysicsManager.can_choose_participant(controller)
                PsychophysicsManager.set_dashboard_participant!(controller, "P99")
                @test first_run.participant_id == "P01"
                @test PsychophysicsManager.edit_dashboard_parameter!(controller, "ex_par.repeats", "3")
                @test !isfile(joinpath(runs_dir, "first.json"))
                @test !isfile(scenario_state_path(plan))
                @test PsychophysicsManager.keyboard_control(controller) === :start

                # Start writes the run to the file its plan gives it, and its end is
                # recorded beside the plan
                @test PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test first_run.state == FINISHED && length(first_run.history) == 6
                @test first_run.save_path == joinpath(runs_dir, "first.json")
                @test load_session(first_run.save_path).id == first_run.id
                @test states() == [:complete, :to_run]
                @test !isdir("out") || !any(endswith(".json"), readdir("out"))
                @test controller.message == ui_label(:msg_run_complete; run = "first",
                                                     next = "second")

                # The plan's next run follows it, not a new session of this one: one press
                # prepares it, Enter or Space included, and Start runs it
                @test PsychophysicsManager.control_buttons(controller) == [:next_run]
                @test !PsychophysicsManager.action_state(controller).can_start_new
                @test PsychophysicsManager.keyboard_control(controller) === :next_run
                @test PsychophysicsManager.prepare_next_scenario_run!(controller)
                second_run = controller.session
                @test second_run.participant_id == "P02" && second_run.ex_par.repeats == 2
                @test PsychophysicsManager.control_buttons(controller) == [:start]
                @test PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test second_run.state == FINISHED
                @test controller.message == ui_label(:msg_plan_finished; run = "second")
                @test !PsychophysicsManager.action_state(controller).can_prepare_next
                @test PsychophysicsManager.keyboard_control(controller) === nothing
                @test PsychophysicsManager.prepare_next_scenario_run!(controller) == false
                @test PsychophysicsManager.dashboard_plans()[2].runs == "2 / 2"
                @test PsychophysicsManager.dashboard_plans()[2].next == ui_label(:plan_complete)

                # A complete plan is chosen with nothing in hand
                @test PsychophysicsManager.choose_scenario!(controller, plan) == false
                @test controller.session === nothing
                @test controller.message == ui_label(:msg_plan_complete; plan = "Two runs")

                # A run whose session was discarded is measured again; one pinned to its
                # file and never finished — a crash after Start — runs on in that file
                discard_session(joinpath(runs_dir, "second.json"))
                @test states() == [:complete, :to_run]
                pinned = begin_scenario_run!(prepare_next_run(plan)).session
                @test states() == [:complete, :to_continue]
                @test PsychophysicsManager.choose_scenario!(controller, plan)
                @test controller.session.id == pinned.id && controller.plan_run.kind === :resume
                @test controller.chosen == joinpath(runs_dir, "second.json")
                @test controller.message == ui_label(:msg_run_continues; position = 2,
                    total = 2, plan = "Two runs", run = "second", file = "second.json")
                @test PsychophysicsManager.start_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED && states() == [:complete, :complete]

                # A run that was stopped holds up the plan; so does a file in the way. (The
                # operator empties the discarded sessions first: a discard never overwrites)
                rm(joinpath(runs_dir, "discarded"); recursive = true)
                discard_session(joinpath(runs_dir, "second.json"))
                begin_scenario_run!(prepare_next_run(plan))
                second_file = joinpath(runs_dir, "second.json")
                write(second_file, replace(read(second_file, String), "\"READY\"" => "\"ABORTED\""))
                @test states() == [:complete, :aborted]
                @test PsychophysicsManager.dashboard_plan_runs(plan)[2].state == ui_label(:run_aborted)
                @test PsychophysicsManager.choose_scenario!(controller, plan) == false
                @test occursin("aborted", controller.message)
                occupied = joinpath(setups, "Occupied.toml")
                write(occupied, """
                    [[run]]
                    id = "again"
                    source = "base.json"
                    destination = "../runs/first.json"
                    """)
                @test [entry.second for entry in scenario_run_states(occupied)] == [:occupied]
                @test PsychophysicsManager.dashboard_plan_runs(occupied)[1].state == ui_label(:run_occupied)

                # Choosing another setup leaves the plan, and the participant is chosen again
                @test PsychophysicsManager.choose_scenario!(controller, plan) == false
                @test PsychophysicsManager.choose_setup!(controller, joinpath(setups, "base.json"))
                @test controller.plan === nothing && controller.plan_run === nothing
                @test PsychophysicsManager.can_choose_participant(controller)
            end
        end
    end

    @testset "A changed stimulus program waits for the operator's choice" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                # A session paused after its first trial, presented by a program other
                # than the emulator that will continue it
                function paused_session(participant)
                    session = SessionContext(participant,
                        ExperimentParameters("Changed", :level, [1.0, 2.0], 1),
                        BaseStimulusParameters(100.0), ConstantStimuli())
                    session.engine_name = "EmulatorEngine"
                    start_session!(session)
                    session.environment["stimulus_program"] = "EmulatorEngine (PsychophysicsManager)"
                    session.environment["stimulus_version"] = "git 0000000"
                    run_next_trial!(session, EmulatorEngine())
                    session.state = PAUSED
                    return save_session_checkpoint(session, resolve_data_dir())
                end

                controller = DashboardController()
                path = paused_session("P01")
                @test PsychophysicsManager.open_previous_session!(controller, path)
                paused = controller.session
                PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test paused.state == PAUSED && length(paused.history) == 1
                refusal = controller.changed_stimulus
                @test refusal isa StimulusChangedError
                @test refusal.recorded == "EmulatorEngine (PsychophysicsManager), git 0000000"
                @test controller.message == ui_label(:msg_stimulus_changed;
                    recorded = refusal.recorded, current = refusal.current)
                @test PsychophysicsManager.control_buttons(controller) == [:continue_changed, :start_new]

                # Continuing records the change, from the trial it presents first
                @test PsychophysicsManager.continue_changed_stimulus!(controller)
                wait(controller.run_task)
                @test paused.state == FINISHED && controller.changed_stimulus === nothing
                @test haskey(paused.environment, "stimulus_version_from_trial_2")
                @test PsychophysicsManager.continue_changed_stimulus!(controller) == false

                # Or a new session starts, and the paused one stays as it was
                other = paused_session("P02")
                @test PsychophysicsManager.open_previous_session!(controller, other)
                PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test PsychophysicsManager.action_state(controller).can_start_new
                @test PsychophysicsManager.start_new_session!(controller)
                wait(controller.run_task)
                @test controller.session.participant_id == "P02"
                @test controller.session.state == FINISHED
                @test controller.session.save_path != other
                @test load_session(other).state == PAUSED
            end
        end
    end

    @testset "A paused session gives way to another choice in Browse" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext(ExperimentParameters("Aside", :level, [1.0, 2.0], 2),
                                          BaseStimulusParameters(100.0), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                setup = save_session_checkpoint(template, resolve_templates_dir();
                                                filename = "Aside.json")
                controller = DashboardController()
                @test PsychophysicsManager.choose_setup!(controller, setup)
                running = controller.session
                # Paused after its first trial, its loop waiting
                on_session_event!(running) do session, event
                    event === :trial_completed && length(session.history) == 1 && pause!(session)
                end
                @test PsychophysicsManager.start_experiment!(controller)
                timedwait(() -> running.state == PAUSED, 10.0)
                @test running.state == PAUSED && PsychophysicsManager.is_running(controller)
                @test PsychophysicsManager.action_state(controller).can_load

                # Another choice sets it aside, and is made once its loop has ended
                @test PsychophysicsManager.after_setting_aside!(controller) do
                    PsychophysicsManager.choose_setup!(controller, setup)
                end
                @test !PsychophysicsManager.action_state(controller).can_resume
                # The panel says where it went, beside what the choice says
                aside = ui_label(:msg_set_aside; file = basename(running.save_path))
                timedwait(() -> startswith(controller.message, aside), 10.0)
                @test startswith(controller.message, aside)
                @test istaskdone(controller.run_task)
                @test controller.session !== running && controller.session.state == READY
                @test running.state == PAUSED && length(running.history) == 1
                @test load_session(running.save_path).state == PAUSED

                # It continues later, from its own file, to its end
                @test PsychophysicsManager.open_previous_session!(controller, running.save_path)
                PsychophysicsManager.resume_experiment!(controller)
                wait(controller.run_task)
                @test controller.session.state == FINISHED
                @test length(controller.session.history) == 4
            end
        end
    end

    @testset "Closing the dashboard sets a running session aside, once confirmed" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                template = SessionContext(ExperimentParameters("Closing", :level, [1.0, 2.0], 2),
                                          BaseStimulusParameters(100.0), ConstantStimuli())
                template.engine_name = "EmulatorEngine"
                setup = save_session_checkpoint(template, resolve_templates_dir();
                                                filename = "Closing.json")
                closed = Ref(false)
                close_window = () -> (closed[] = true; nothing)

                # Nothing running: the window closes at once
                controller = DashboardController()
                @test PsychophysicsManager.close_dashboard!(close_window, controller)
                @test closed[]

                # The dashboard's own loop, its session paused after the first trial
                closed[] = false
                @test PsychophysicsManager.choose_setup!(controller, setup)
                running = controller.session
                on_session_event!(running) do session, event
                    event === :trial_completed && length(session.history) == 1 && pause!(session)
                end
                @test PsychophysicsManager.start_experiment!(controller)
                timedwait(() -> running.state == PAUSED, 10.0)
                @test PsychophysicsManager.is_running(controller)
                # The first request only asks
                @test !PsychophysicsManager.close_dashboard!(close_window, controller)
                @test !closed[] && controller.message == ui_label(:confirm_close)
                # The second sets the session aside and closes once its loop has ended
                @test PsychophysicsManager.close_dashboard!(close_window, controller)
                timedwait(() -> closed[], 10.0)
                @test closed[] && istaskdone(controller.run_task)
                @test running.state == PAUSED && load_session(running.save_path).state == PAUSED

                # A script's loop beside the dashboard: the session is paused, and the
                # loop ends once the window has closed (`run_when_started!`)
                scripted = SessionContext(ExperimentParameters("Scripted", :level, [1.0, 2.0], 2),
                                          BaseStimulusParameters(100.0), ConstantStimuli())
                window = Channel{Nothing}(1)   # stands in for the window: open until closed
                script_controller = DashboardController(scripted)
                outcomes = Bool[]
                on_session_event!(scripted) do session, event
                    if event === :trial_completed && length(session.history) == 1
                        for _ in 1:2
                            push!(outcomes, PsychophysicsManager.close_dashboard!(
                                () -> close(window), script_controller))
                            push!(outcomes, isopen(window))
                        end
                    end
                end
                start_session!(scripted)
                loop = @async run_when_started!(scripted, EmulatorEngine(), window;
                                                report = :silent)
                timedwait(() -> istaskdone(loop), 10.0)
                # Asked first, closed on the second request
                @test outcomes == [false, true, true, false]
                @test istaskdone(loop)
                @test scripted.state == PAUSED && length(scripted.history) == 1
            end
        end
    end

    @testset "A setup its stimulus refuses is not loaded" begin
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\ntemplates_dir = \"setups\"\n")
                bad = SessionContext(ExperimentParameters("Bad", :contrast, [0.1, 0.2], 1),
                                     Gabor(), ConstantStimuli())
                bad.engine_name = "EmulatorEngine"
                path = save_session_checkpoint(bad, resolve_templates_dir(); filename = "Bad.json")
                controller = DashboardController()
                @test PsychophysicsManager.choose_setup!(controller, path) == false
                @test controller.session === nothing
                @test occursin("target_interval", controller.message)
                # A saved session is still opened, for its data; its parameters cannot be
                # shown, which the Parameters view says instead of drawing them
                @test PsychophysicsManager.open_previous_session!(controller, path)
                @test_throws ArgumentError PsychophysicsManager.dashboard_setup_rows(controller.session)
                # and it does not start, nor gets a file
                @test PsychophysicsManager.start_experiment!(controller) == false
                @test startswith(controller.message, ui_label(:msg_cannot_start; error = ""))
                @test controller.session.state == READY && !isdir("out")
            end
        end
    end

    @testset "Settings are viewed and changed from the dashboard" begin
        mktempdir() do dir
            user = joinpath(dir, "rig", "settings.toml")
            mkpath(dirname(user))
            write(user, "[display]\nscreen_idx = 1\nfullscreen = true\n\n[rig]\nname = \"Booth\"\n" *
                        "pixel_pitch_mm = 0.25\nviewing_distance_mm = 1000\nframe_ms = 16.7\n")
            withenv(PsychophysicsManager.USER_SETTINGS_VARIABLE => user) do; cd(dir) do
                path = joinpath(dir, "settings.toml")
                write(path, "# The laboratory\n[display]\nscreen_idx = 2  # the HDMI monitor\n")
                controller = DashboardController()
                sections = PsychophysicsManager.dashboard_settings()
                @test [section.name for section in sections] ==
                      ["storage", "ui", "display", "rig", "audio", "input", "combining",
                       "plot", "control", "remote"]
                section(name) = only(filter(s -> s.name == name, sections))
                row(name, key) = only(filter(r -> r.key == key, section(name).rows))
                # The value in effect, its default, and the file it came from; a project's
                # value marks the rig's it replaces
                @test row("display", "screen_idx").source == path
                @test row("display", "screen_idx").replaces == "1"
                @test row("display", "fullscreen").source == user
                @test row("display", "fullscreen").replaces === nothing
                @test row("display", "width").source === nothing
                @test section("display").target == path
                @test section("storage").target == path
                @test section("audio").target == user
                # The rig's constants, its own keys first, a pixel's angle derived
                @test [r.key for r in section("rig").rows] ==
                      ["name", "pixel_pitch_mm", "viewing_distance_mm", "pixel_arcmin", "frame_ms"]
                @test row("rig", "frame_ms").tip == :tip_setting_rig_constant
                @test startswith(row("rig", "pixel_arcmin").default, "0.8594, from")
                @test row("display", "screen_idx").value == "2"
                @test row("display", "screen_idx").in_file
                @test row("display", "width").value == "1200"
                @test row("display", "width").default == "1200"
                @test !row("display", "width").in_file
                @test row("display", "dashboard_screen_idx").default == "not set"
                @test row("display", "screen_name").default == "empty"
                @test row("display", "presentation_mode").value == "dual_screen"
                @test row("display", "presentation_mode").default == "dual_screen"
                @test row("display", "presentation_mode").choices == ["dual_screen", "single_screen"]
                @test row("display", "presentation_mode").tip == :tip_setting_display_presentation_mode
                @test row("storage", "data_dir").value == "data"
                @test row("remote", "port").default == "required"
                @test isempty(unread_settings()) && PsychophysicsManager.unread_settings_text() === nothing
                # What no setting reads — a misspelt key or section — is named with its file
                open(path, "a") do io
                    print(io, "screen_nmae = \"HDMI\"\n[dispaly]\nscreen_idx = 1\n")
                end
                @test unread_settings() == [path => "[dispaly]", path => "[display] screen_nmae"]
                @test occursin("[display] screen_nmae ($path)",
                               PsychophysicsManager.unread_settings_text())
                write(path, "# The laboratory\n[display]\nscreen_idx = 2  # the HDMI monitor\n")
                @test "lt" in row("ui", "language").choices
                @test row("combining", "observer").tip == :tip_check_observer

                # A value typed in is written into the file, and the panel says where
                @test PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                   "width", "1600")
                @test occursin(path, controller.message)
                @test load_display_config().window_size == (1600, 800)
                @test occursin("screen_idx = 2  # the HDMI monitor", read(path, String))
                # A refused value: the panel says why, and the file stays as it was
                text = read(path, String)
                @test !PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                    "width", "wide")
                @test startswith(controller.message, "Not written") &&
                      occursin("width", controller.message)
                @test read(path, String) == text
                # An empty number, and Reset, return a setting to its default
                @test PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                   "width", "")
                @test load_display_config().window_size == (1200, 800)
                @test PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                   "fullscreen", "true")
                @test load_display_config().fullscreen
                @test occursin(user, controller.message)
                @test PsychophysicsManager.reset_dashboard_setting!(controller, "display",
                                                                    "fullscreen")
                @test !load_display_config().fullscreen
                @test occursin("default", controller.message)
                # presentation_mode updates via Settings and refuses unknown modes
                @test PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                   "presentation_mode",
                                                                   "single_screen")
                @test load_display_config().presentation_mode === :single_screen
                @test controller.presentation_mode === :single_screen
                @test !PsychophysicsManager.edit_dashboard_setting!(controller, "display",
                                                                    "presentation_mode",
                                                                    "triple_screen")
                @test PsychophysicsManager.reset_dashboard_setting!(controller, "display",
                                                                    "presentation_mode")
                @test load_display_config().presentation_mode === :dual_screen
                @test controller.presentation_mode === :dual_screen
                # A section no file defines goes to the file chosen for it
                @test PsychophysicsManager.edit_dashboard_setting!(
                    controller, "audio", "output_device", "Laboratory Output"; target = path)
                @test load_audio_output_device() == "Laboratory Output"
                # The language applies at once
                try
                    @test PsychophysicsManager.edit_dashboard_setting!(controller, "ui",
                                                                       "language", "lt")
                    @test ui_language() == "lt"
                    @test occursin("language = \"lt\"", read(user, String))
                finally
                    set_ui_language!("en")
                end
            end; end
        end
    end

    @testset "One list of stimuli in the dashboard" begin
        session = SessionContext(
            "P01",
            ExperimentParameters("Visual", [:contrast, :target_interval], [[0.1, 0.2], [1, 2]], 1),
            Gabor(),
            ConstantStimuli();
            tags = ["pilot"],
        )
        session.engine_name = "GeometryVisualEngine"

        # 1. dashboard_setup_rows gives one stimulus row with choices (and no engine row)
        setup = PsychophysicsManager.dashboard_setup_rows(session)
        stim_row = only(filter(r -> r.key == "stimulus", setup.experiment))
        @test stim_row.label == ui_label(:setup_stimulus)
        @test stim_row.value == "Gabor"
        @test issubset(["Gabor", "MarkerLayout", "TemporalOppelKundt"],
                       [c.second for c in stim_row.choices])
        @test !any(r -> r.label == "Stimulus program" || r.label == "Stimulų programa" ||
                        r.value == session.engine_name, setup.experiment)

        # Worker-declared stimuli included when declared is provided
        ws = WorkerStimulus("remote_flashed"; flash_ms = 50, color = "white")
        setup_with_worker = PsychophysicsManager.dashboard_setup_rows(session; declared = [ws])
        stim_row_worker = only(filter(r -> r.key == "stimulus", setup_with_worker.experiment))
        @test "remote_flashed" in [c.second for c in stim_row_worker.choices]

        # The stimulus in hand stays listed when nothing offers it: a worker's, unconnected
        held = SessionContext("P04", ExperimentParameters("Held", :flash_ms, [50], 1),
                              deepcopy(ws), ConstantStimuli())
        held_row = only(filter(r -> r.key == "stimulus",
                               PsychophysicsManager.dashboard_setup_rows(held).experiment))
        @test held_row.value == "remote_flashed"
        @test "remote_flashed" in last.(held_row.choices)

        # The tooltip: the description, and the engine the session is presented by, which
        # need not be the one the stimulus is registered with
        @test occursin(PsychophysicsManager.stimulus_description(session.stim_par),
                       stim_row.tooltip)
        @test occursin("GeometryVisualEngine", stim_row.tooltip)
        session.engine_name = "EmulatorEngine"
        tip = only(filter(r -> r.key == "stimulus",
                          PsychophysicsManager.dashboard_setup_rows(session).experiment)).tooltip
        @test occursin("EmulatorEngine", tip) && !occursin("GeometryVisualEngine", tip)
        session.engine_name = "GeometryVisualEngine"

        # and the program recorded as presenting the session, with its version
        session.environment["stimulus_program"] = "GeometryVisualEngine (PsychophysicsManagerGLMakieExt)"
        session.environment["stimulus_version"] = "git abc1234, engine.jl sha256 5678"
        session.environment["stimulus_version_stated"] = "1.2.3"
        setup_rec = PsychophysicsManager.dashboard_setup_rows(session)
        tip_rec = only(filter(r -> r.key == "stimulus", setup_rec.experiment)).tooltip
        @test occursin("GeometryVisualEngine (PsychophysicsManagerGLMakieExt)", tip_rec)
        @test occursin("git abc1234", tip_rec)
        @test occursin("1.2.3", tip_rec)
        empty!(session.environment)

        # 2. Every stimulus parameter, in the stimulus's own order
        @test [r.label for r in setup.stimulus] ==
              string.(parameter_names(session.stim_par))

        # 3. Choosing a stimulus through the controller changes stimulus and keeps/replaces variables
        controller = DashboardController(session; owns_engine = true)
        ctrl_session = controller.session
        @test ctrl_session.stim_par isa Gabor

        # Change to MarkerLayout: :contrast and :target_interval are not in MarkerLayout,
        # replaced by first numeric parameter at default (:Ref). A preview's engine was
        # opened for the stimulus it showed, and closes
        preview = PreviewWindowEngine(true)
        controller.preview_engine = preview
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stimulus", "MarkerLayout")
        @test !preview.open && controller.preview_engine === nothing
        @test ctrl_session.stim_par isa MarkerLayout
        @test ctrl_session.engine_name == "GeometryVisualEngine"
        @test ctrl_session.ex_par.indep_var_names == [:Ref]

        # Change to TemporalOppelKundt
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stimulus", "TemporalOppelKundt")
        @test ctrl_session.stim_par isa TemporalOppelKundt
        @test ctrl_session.engine_name == "AudioStimulusEngine"

        # 4. Refused choice leaves session unchanged
        @test !PsychophysicsManager.edit_dashboard_parameter!(controller, "stimulus", "NoSuchStimulus")
        @test startswith(controller.message, ui_label(:msg_parameter_refused; error = ""))
        @test ctrl_session.stim_par isa TemporalOppelKundt
        @test ctrl_session.engine_name == "AudioStimulusEngine"

        # Refusal when method cannot adjust stimulus
        mutable struct EmptyUIDummyStimulus <: AbstractStimulusParameters end
        register_stimulus!(EmptyUIDummyStimulus; engine = :EmulatorEngine, description = "Empty UI dummy")
        adj_session = SessionContext(
            "P03",
            ExperimentParameters("Adj", :Ref, [100.0], 1),
            MarkerLayout(),
            Adjustment(dep_var = :Diff, dep_range = -5.0:1.0:5.0),
        )
        adj_ctrl = DashboardController(adj_session; owns_engine = true)
        @test !PsychophysicsManager.edit_dashboard_parameter!(adj_ctrl, "stimulus", "EmptyUIDummyStimulus")
        @test adj_session.stim_par isa MarkerLayout

        # 5. Choosing when session has started is refused
        ctrl_session.state = RUNNING
        @test !PsychophysicsManager.edit_dashboard_parameter!(controller, "stimulus", "Gabor")
        @test controller.message == ui_label(:msg_parameters_fixed)
        @test ctrl_session.stim_par isa TemporalOppelKundt

        # 6. Choosing after session finished prepares a new session
        ctrl_session.state = FINISHED
        @test PsychophysicsManager.edit_dashboard_parameter!(controller, "stimulus", "MarkerLayout")
        @test ctrl_session.stim_par isa TemporalOppelKundt # Finished session unchanged
        prepared = PsychophysicsManager.prepared_session(controller)
        @test prepared !== nothing
        @test prepared.stim_par isa MarkerLayout # Prepared session has the new stimulus
    end

    @testset "The window icon is read at each size it is drawn in" begin
        icons = PsychophysicsManager.window_icon_images()
        @test size.(icons) == [(16, 16), (32, 32), (48, 48)]
        for icon in icons
            # The tile's rounded corner is transparent, its middle opaque
            @test icon[1, 1][4] == 0x00
            @test icon[end ÷ 2, end ÷ 2][4] == 0xff
        end

        # The desktop entry names the dashboard's window class and an icon that exists
        mktempdir() do dir
            entry = read(install_desktop_icon(directory = dir), String)
            @test occursin("StartupWMClass=PsychophysicsManager\n", entry)
            icon = only(m.captures[1] for m in eachmatch(r"^Icon=(.*)$"m, entry))
            @test isfile(icon)
        end
    end

    @testset "Data view and [plot] options" begin
        function make_choice_session(participant, start, answers;
                                     experiment = "Exp",
                                     stim = MarkerLayout(Ref = 10.0),
                                     scored = false,
                                     comment = nothing)
            ex_par = ExperimentParameters(experiment, :Diff, [-2.0, 0.0, 2.0, 4.0], 1)
            method = ConstantStimuli()
            initialize_method!(method, ex_par)
            method.current_idx = length(answers) + 1
            s = SessionContext(participant, ex_par, stim, method)
            s.engine_name = "EmulatorEngine"
            s.start_time = start
            s.current_trial_idx = length(answers) + 1
            s.state = FINISHED
            for (idx, (level, resp)) in enumerate(answers)
                correct = scored ? (resp == 1) : nothing
                push!(s.history, Trial(idx, start + idx, start + idx + 0.5,
                                       [level], resp, true, :estimated, correct))
            end
            comment === nothing || add_comment!(s, comment)
            return s
        end

        s1 = make_choice_session("P01", 1.700000e9,
                                 [(-2.0, 0), (0.0, 0), (2.0, 1), (4.0, 1)];
                                 comment = "first note")
        s2 = make_choice_session("P01", 1.7000036e9,
                                 [(-2.0, 0), (0.0, 1), (2.0, 1), (4.0, 1)])
        s3 = make_choice_session("P01", 1.7000072e9,
                                 [(-2.0, 0), (0.0, 1), (2.0, 0), (4.0, 1)];
                                 comment = "older")
        add_comment!(s3, "final note")

        # 1. Pooled plot of three sessions of one series matches AnalysisSet aggregation
        set = AnalysisSet([s1, s2, s3]; checks = collect(COMBINING_CHECKS))
        expected = get_aggregated_data(set)

        pooled_sem = PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s3], PlotOptions(split = :pooled, spread = :sem))
        @test isempty(pooled_sem.note)
        @test length(pooled_sem.panels) == 1
        @test length(pooled_sem.panels[1]) == 1
        line_sem = only(only(pooled_sem.panels))
        @test line_sem.label == "P01"
        @test line_sem.x == [p.level for p in expected]
        @test line_sem.y == [p.mean_response for p in expected]
        @test line_sem.n == [p.n for p in expected]
        @test line_sem.err_lo ≈ [p.sem for p in expected]
        @test line_sem.err_hi ≈ [p.sem for p in expected]
        @test length(line_sem.trials) == 12
        @test length(line_sem.curve_x) == 100

        pooled_ci = PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s3], PlotOptions(split = :pooled, spread = :ci))
        line_ci = only(only(pooled_ci.panels))
        @test line_ci.x == [p.level for p in expected]
        @test line_ci.y == [p.mean_response for p in expected]
        @test line_ci.n == [p.n for p in expected]
        @test line_ci.y .- line_ci.err_lo ≈ [p.ci_lo for p in expected]
        @test line_ci.y .+ line_ci.err_hi ≈ [p.ci_hi for p in expected]

        # Scored task uses binomial SE for :sem and correct_ci_* (Wilson) for :ci
        sc1 = make_choice_session("P01", 1.700000e9,
                                  [(-2.0, 0), (0.0, 1), (2.0, 1), (4.0, 1)]; scored = true)
        sc2 = make_choice_session("P01", 1.7000036e9,
                                  [(-2.0, 1), (0.0, 0), (2.0, 1), (4.0, 1)]; scored = true)
        sc_agg = get_aggregated_data(AnalysisSet([sc1, sc2]; checks = collect(COMBINING_CHECKS)))
        sc_ci = only(only(PsychophysicsManager.dashboard_data_plot(
            [sc1, sc2], PlotOptions(split = :pooled, spread = :ci)).panels))
        @test sc_ci.y == [p.proportion_correct for p in sc_agg]
        @test sc_ci.y .- sc_ci.err_lo ≈ [p.correct_ci_lo for p in sc_agg]
        @test sc_ci.y .+ sc_ci.err_hi ≈ [p.correct_ci_hi for p in sc_agg]
        sc_sem = only(only(PsychophysicsManager.dashboard_data_plot(
            [sc1, sc2], PlotOptions(split = :pooled, spread = :sem)).panels))
        @test sc_sem.err_lo ≈ [sqrt(p.proportion_correct * (1 - p.proportion_correct) / p.n)
                               for p in sc_agg]

        # 2. overlaid gives one line per session in one panel; panels one panel per session
        overlaid = PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s3], PlotOptions(split = :overlaid))
        @test length(overlaid.panels) == 1
        @test length(overlaid.panels[1]) == 3
        @test [l.y for l in overlaid.panels[1]] ==
              [[0.0, 0.0, 1.0, 1.0], [0.0, 1.0, 1.0, 1.0], [0.0, 1.0, 0.0, 1.0]]
        @test all(l -> occursin("P01", l.label), overlaid.panels[1])

        panels = PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s3], PlotOptions(split = :panels))
        @test length(panels.panels) == 3
        @test all(p -> length(p) == 1, panels.panels)
        @test [only(p).y for p in panels.panels] ==
              [[0.0, 0.0, 1.0, 1.0], [0.0, 1.0, 1.0, 1.0], [0.0, 1.0, 0.0, 1.0]]
        @test [spec.title for spec in panels.panel_specs] == [only(p).label for p in panels.panels]

        # 3. Two series differing in a stimulus parameter stay separate even when pooled
        s_ref20 = make_choice_session("P01", 1.7000108e9,
                                      [(-2.0, 0), (0.0, 0), (2.0, 0), (4.0, 1)];
                                      stim = MarkerLayout(Ref = 20.0))
        two_series = PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s_ref20], PlotOptions(split = :pooled))
        @test length(two_series.panels) == 1
        @test length(two_series.panels[1]) == 2
        @test occursin("Ref", two_series.note)
        @test any(l -> occursin("Ref = 10", l.label), two_series.panels[1])
        @test any(l -> occursin("Ref = 20", l.label), two_series.panels[1])

        # Explicit group where admit_session! refuses a member draws it separately and notes it
        refused_plot = PsychophysicsManager.dashboard_data_plot(
            [[s1, s_ref20]], PlotOptions(split = :pooled))
        @test length(refused_plot.panels) == 1
        @test length(refused_plot.panels[1]) == 2
        @test occursin("Ref", refused_plot.note)

        # 4. Options: converted = false, fit = false, smooth = true, spread = :none/:sd, raw = false
        conv_s = make_choice_session("P01", 1.700000e9,
                                     [(-2.0, 0), (0.0, 0), (2.0, 1), (4.0, 1)])
        set_unit_conversion!(conv_s, :Diff, UnitConversion("Offset (arcmin)"; scale = 10.0))
        @test PsychophysicsManager.dashboard_plot_spec(conv_s; converted = true).x_label == "Offset (arcmin)"
        @test PsychophysicsManager.dashboard_plot_spec(conv_s; converted = false).x_label == "Diff"

        raw_plot = PsychophysicsManager.dashboard_data_plot(
            [conv_s], PlotOptions(converted = false, fit = false, smooth = true,
                                  spread = :none, raw = false))
        raw_line = only(only(raw_plot.panels))
        @test raw_plot.spec.x_label == "Diff"
        @test raw_line.x == [-2.0, 0.0, 2.0, 4.0]
        @test isempty(raw_line.curve_x) && isempty(raw_line.curve_y)
        @test isempty(raw_line.err_lo) && isempty(raw_line.err_hi)
        @test isempty(raw_line.trials)
        @test raw_line.smooth_y ≈ PsychophysicsManager.smoothed_means(
            get_aggregated_data(conv_s; converted = false); values = raw_line.y)

        sd_line = only(only(PsychophysicsManager.dashboard_data_plot(
            [s1, s2, s3], PlotOptions(split = :pooled, spread = :sd)).panels))
        @test sd_line.err_lo ≈ [p.sd for p in expected]
        @test sd_line.err_hi ≈ [p.sd for p in expected]

        # 5. Live plot (dashboard_plot_series) follows PlotOptions
        live_none = PsychophysicsManager.dashboard_plot_series(
            conv_s, PlotOptions(spread = :none, fit = false, smooth = true,
                                raw = false, converted = false))
        @test live_none.x == [-2.0, 0.0, 2.0, 4.0]
        @test live_none.spec.x_label == "Diff"
        @test isempty(live_none.err) && isempty(live_none.err_lo) && isempty(live_none.err_hi)
        @test isempty(live_none.curve_x) && isempty(live_none.trials)
        @test live_none.smooth_y ≈ PsychophysicsManager.smoothed_means(
            get_aggregated_data(conv_s; converted = false); values = live_none.y)
        # Point lookup respects converted = false
        pt_raw = only(filter(p -> p.level == 2.0, live_none.points))
        @test PsychophysicsManager.dashboard_point_condition(conv_s, pt_raw; converted = false) == [2.0]

        live_ci = PsychophysicsManager.dashboard_plot_series(
            s1, PlotOptions(spread = :ci))
        s1_agg = get_aggregated_data(s1)
        @test live_ci.y .- live_ci.err_lo ≈ [p.ci_lo for p in s1_agg]
        @test live_ci.y .+ live_ci.err_hi ≈ [p.ci_hi for p in s1_agg]

        # 6. data_view_rows for two sessions and for a single session in hand
        rows2 = PsychophysicsManager.data_view_rows([s1, s3])
        @test length(rows2) == 2
        @test rows2[1].date == PsychophysicsManager.started_text(s1.start_time)
        @test rows2[1].trials == "4 / 4"
        @test rows2[1].state == ui_label(:state_finished)
        @test rows2[1].comment == "first note"
        @test rows2[1].tickable == true
        @test rows2[2].comment == "final note"
        @test rows2[2].tickable == true

        row_single = only(PsychophysicsManager.data_view_rows(s1))
        @test row_single.tickable == false && row_single.comment == "first note"
        @test isempty(PsychophysicsManager.data_view_rows(nothing))

        # 7. Earlier sessions of a series (two earlier sessions pooled + dimmed) and SessionCache
        mktempdir() do dir
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                data_dir = resolve_data_dir()
                p1 = save_session_checkpoint(s1, data_dir)
                p2 = save_session_checkpoint(s2, data_dir)
                p3 = save_session_checkpoint(s3, data_dir)
                p_other = save_session_checkpoint(s_ref20, data_dir)
                entries = browse_sessions(data_dir)
                cache = PsychophysicsManager.SessionCache()

                s3_loaded = load_session(p3)
                others = PsychophysicsManager.earlier_series_entries(s3_loaded, entries)
                @test sort([e.path for e in others]) == sort(abspath.([p1, p2]))

                earlier = PsychophysicsManager.earlier_sessions_line(
                    s3_loaded, entries, cache, PlotOptions(spread = :sem))
                @test earlier !== nothing
                @test earlier.dimmed == true
                @test isempty(earlier.trials)
                expected_earlier = get_aggregated_data(
                    AnalysisSet([s1, s2]; checks = collect(COMBINING_CHECKS)))
                @test earlier.x == [p.level for p in expected_earlier]
                @test earlier.y == [p.mean_response for p in expected_earlier]
                @test earlier.n == [p.n for p in expected_earlier]
                @test earlier.err_lo ≈ [p.sem for p in expected_earlier]

                # Other series has no earlier sessions
                @test PsychophysicsManager.earlier_sessions_line(
                    load_session(p_other), entries, cache, PlotOptions()) === nothing

                # SessionCache hits on unchanged file and reports unreadable files in note
                cached1, err1 = PsychophysicsManager.load_cached_session!(cache, p1)
                cached2, err2 = PsychophysicsManager.load_cached_session!(cache, p1)
                @test err1 === nothing && err2 === nothing && cached1 === cached2

                bad_path = joinpath(data_dir, "corrupt.json")
                write(bad_path, "{broken json")
                res = PsychophysicsManager.load_ticked_data_view(
                    [p1, bad_path], entries, cache, PlotOptions())
                @test length(res.plot.panels) == 1 && length(res.plot.panels[1]) == 1
                @test occursin("corrupt.json", res.plot.note)
                @test length(res.rows) == 1
                @test res.rows[1].trials == "4 / 4"

                # Live plot mode vs ticked mode, and dashboard plot option persistence
                ctrl = DashboardController(; owns_engine = true)
                @test PsychophysicsManager.is_live_plot_mode(ctrl)
                PsychophysicsManager.tick_session!(ctrl, abspath(p1), true)
                @test !PsychophysicsManager.is_live_plot_mode(ctrl)
                PsychophysicsManager.clear_ticks!(ctrl)
                @test PsychophysicsManager.is_live_plot_mode(ctrl)

                user_file = joinpath(dir, "user_settings.toml")
                withenv("PSYCHOPHYSICSMANAGER_SETTINGS" => user_file) do
                    @test PsychophysicsManager.set_dashboard_plot_option!(ctrl, :smooth, true)
                    @test load_plot_options().smooth == true
                    @test !PsychophysicsManager.set_dashboard_plot_option!(ctrl, :spread, "bad")
                    @test !isempty(ctrl.message)
                end

                # Dashboard view label is Data / Duomenys
                @test ui_label(:view_plot) == "Data"
                try
                    set_ui_language!("lt")
                    @test ui_label(:view_plot) == "Duomenys"
                finally
                    set_ui_language!("en")
                end
            end
        end
    end

    @testset "Single-screen presentation mode" begin
        pres = PsychophysicsManager.dashboard_presentation_state
        active = (controls_visible = true, skip_redraw = false,
                  accept_input = true, stimulus_focused = false)
        yielded = (controls_visible = false, skip_redraw = true,
                   accept_input = false, stimulus_focused = true)

        @testset "Pure mode-to-dashboard-state transitions" begin
            # Invalid mode is refused
            @test_throws ArgumentError pres(:triple_screen, RUNNING, true)

            # :dual_screen keeps the dashboard active in every state and trial phase
            for state in (nothing, READY, RUNNING, PAUSED, ABORTED, FINISHED),
                trial_under_way in (false, true),
                stimulus_message in (false, true)
                @test pres(:dual_screen, state, trial_under_way; stimulus_message) == active
            end

            # :single_screen yields during a trial (RUNNING + trial_under_way) and restores
            # controls between trials and on every state change (pause, abort/stop, finish)
            @test pres(:single_screen, nothing, false) == active
            @test pres(:single_screen, READY, false) == active
            @test pres(:single_screen, RUNNING, false) == active       # before / between trials
            @test pres(:single_screen, RUNNING, true) == yielded       # trial start
            @test pres(:single_screen, RUNNING, false) == active       # trial end / abandoned
            @test pres(:single_screen, PAUSED, true) == active         # paused mid-trial
            @test pres(:single_screen, PAUSED, false) == active        # paused between trials
            @test pres(:single_screen, ABORTED, true) == active        # stopped/aborted mid-trial
            @test pres(:single_screen, ABORTED, false) == active       # stopped/aborted
            @test pres(:single_screen, FINISHED, false) == active      # finished

            # Stimulus-side participant messages (instructions, inter-trial count,
            # participant-dismissible break, closing text) keep stimulus focus until
            # ended or aborted
            @test pres(:single_screen, RUNNING, false; stimulus_message = true) == yielded
            @test pres(:single_screen, PAUSED, false; stimulus_message = true) == yielded
            @test pres(:single_screen, FINISHED, false; stimulus_message = true) == yielded
            @test pres(:single_screen, ABORTED, false; stimulus_message = true) == active

            # A windowless render-only engine (e.g. audio) relies on the dashboard keyboard
            @test pres(:single_screen, RUNNING, true; stimulus_owns_focus = false) == active
        end

        @testset "Controller mode selection and live session transitions" begin
            @test_throws ArgumentError DashboardController(; presentation_mode = :invalid)
            mktempdir() do dir
                cd(dir) do
                    # Defaults to :dual_screen when unset in settings.toml
                    @test DashboardController().presentation_mode === :dual_screen
                    write("settings.toml", "[display]\npresentation_mode = \"single_screen\"\n")
                    @test DashboardController().presentation_mode === :single_screen
                    # Explicit keyword overrides settings.toml
                    @test DashboardController(; presentation_mode = :dual_screen).presentation_mode ===
                          :dual_screen
                end
            end

            session = make_session()
            controller = DashboardController(session; presentation_mode = :single_screen)
            channel = Channel{Tuple{Int, Float64}}(1)
            source = PsychophysicsManager.ChannelResponseSource(channel)
            @test pres(controller; source) == active

            # Trial start -> yielded; trial end -> active
            start_session!(session)
            @test pres(controller; source) == active
            session.trial_under_way = true
            @test pres(controller; source) == yielded
            session.trial_under_way = false
            @test pres(controller; source) == active

            # Pause and abort restore controls even if trial_under_way was still raised
            session.trial_under_way = true
            pause!(session)
            @test pres(controller; source) == active
            resume!(session)
            @test pres(controller; source) == yielded
            abort!(session)
            @test pres(controller; source) == active
            session.trial_under_way = false

            # Participant message routing: stimulus-side dismissible message yields,
            # operator-only break and dashboard-source messages keep controls visible
            session2 = make_session()
            start_session!(session2)
            ctrl2 = DashboardController(session2; presentation_mode = :single_screen)
            instr = ParticipantMessage(:instructions, "Read this", true, 0.0, () -> true)
            session2.shown_message = instr
            @test pres(ctrl2; source) == yielded
            # When the dashboard's own response source is displaying the message, controls stay
            source.message[] = instr
            @test pres(ctrl2; source) == active
            source.message[] = nothing
            # Operator-dismissible break needs the dashboard's Resume button
            pause!(session2)
            session2.shown_message = ParticipantMessage(:break, "Wait", false, 0.0, () -> true)
            @test pres(ctrl2; source) == active
            # Participant-dismissible break yields to the stimulus window
            session2.shown_message = ParticipantMessage(:break, "Rest", true, 0.0, () -> true)
            @test pres(ctrl2; source) == yielded
            session2.shown_message = nothing
            @test pres(ctrl2; source) == active

            # Windowless render-only engine never hides the dashboard
            resume!(session2)
            session2.trial_under_way = true
            session2.trial_run = PsychophysicsManager.TrialRun(current_task(),
                                                               WindowlessRenderEngine())
            @test !PsychophysicsManager.engine_takes_focus(WindowlessRenderEngine())
            @test PsychophysicsManager.engine_takes_focus(SingleScreenMessageEngine())
            @test pres(ctrl2; source) == active
            session2.trial_run = nothing
            session2.trial_under_way = false
        end

        @testset "Remaining trials between trials" begin
            @test PsychophysicsManager.remaining_valid_trials(nothing) === nothing
            @test PsychophysicsManager.format_remaining_trials(nothing) == ""

            mktempdir() do dir
                cd(dir) do
                    write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                    session = make_session()   # 3 levels × 2 repeats = 6 trials
                    @test PsychophysicsManager.remaining_valid_trials(session) == 6
                    @test PsychophysicsManager.format_remaining_trials(session) ==
                          "Trials remaining: 6"

                    start_session!(session)
                    run_next_trial!(session, EmulatorEngine())
                    @test PsychophysicsManager.remaining_valid_trials(session) == 5
                    @test PsychophysicsManager.format_remaining_trials(session) ==
                          "Trials remaining: 5"

                    # Undo re-queues the trial: remaining count goes back up by 1
                    @test undo_last_trial!(session) == 1
                    @test PsychophysicsManager.remaining_valid_trials(session) == 6

                    # Mark outlier lowers planned valid trials by 1 (remaining unchanged)
                    run_next_trial!(session, EmulatorEngine())
                    @test PsychophysicsManager.remaining_valid_trials(session) == 5
                    @test mark_outlier!(session, 2)
                    @test PsychophysicsManager.remaining_valid_trials(session) == 5

                    # Lithuanian localization
                    try
                        set_ui_language!("lt")
                        @test PsychophysicsManager.format_remaining_trials(session) ==
                              "Liko bandymų: 5"
                    finally
                        set_ui_language!("en")
                    end

                    # Finishing leaves 0 remaining and an empty display line
                    while session.state == RUNNING
                        run_next_trial!(session, EmulatorEngine())
                    end
                    @test PsychophysicsManager.remaining_valid_trials(session) == 0
                    @test PsychophysicsManager.format_remaining_trials(session) == ""
                end
            end

            # Open-ended method with unknown planned count shows nothing
            open_s = SessionContext("Open", ExperimentParameters("Open", :x, [1.0], 1),
                                    BaseStimulusParameters(10.0), OpenEndedUIStubMethod())
            @test PsychophysicsManager.remaining_valid_trials(open_s) === nothing
            @test PsychophysicsManager.format_remaining_trials(open_s) == ""
        end

        @testset "Participant screen receives remaining-trials messages in :single_screen" begin
            mktempdir() do dir
                cd(dir) do
                    write("settings.toml", "[storage]\ndata_dir = \"out\"\n")

                    # Single-screen run via run_when_started! shows remaining trials after
                    # trials 1 and 2 of a 3-trial session, never after the final trial, and
                    # still calls any caller-supplied on_trial_end hook
                    s3 = SessionContext("P1", ExperimentParameters("Three", :level, [1.0, 2.0, 3.0], 1),
                                        BaseStimulusParameters(10.0), ConstantStimuli())
                    ctrl = DashboardController(s3; presentation_mode = :single_screen)
                    engine = SingleScreenMessageEngine(ctrl)
                    dash = MockSingleScreenDashboard(ctrl, Ref(true))
                    seen_trials = Int[]
                    start_session!(s3)
                    run_when_started!(s3, engine, dash; report = :silent,
                                      on_trial_end = s -> push!(seen_trials, length(s.history)))
                    @test s3.state == FINISHED
                    @test !ctrl.inter_trial_message
                    @test seen_trials == [1, 2, 3]
                    @test engine.log == [
                        (:inter_trial, "Trials remaining: 2", false, true),
                        (:inter_trial, "Trials remaining: 1", false, true),
                    ]

                    # Scheduled break skips a redundant remaining-trials flash before the break
                    s_break = SessionContext("P2", ExperimentParameters("Brk", :level, [1.0, 2.0, 3.0], 1),
                                             BaseStimulusParameters(10.0), ConstantStimuli())
                    set_messages!(s_break; break_after = [1], break_text = "Short break")
                    ctrl_b = DashboardController(s_break; presentation_mode = :single_screen)
                    eng_b = SingleScreenMessageEngine(ctrl_b)
                    dash_b = MockSingleScreenDashboard(ctrl_b, Ref(true))
                    start_session!(s_break)
                    run_when_started!(s_break, eng_b, dash_b; report = :silent)
                    @test s_break.state == FINISHED
                    @test eng_b.log == [
                        (:break, "Short break", true, false),
                        (:inter_trial, "Trials remaining: 1", false, true),
                    ]

                    # :dual_screen preserves existing behaviour: no inter-trial messages
                    s_dual = SessionContext("P3", ExperimentParameters("Dual", :level, [1.0, 2.0, 3.0], 1),
                                            BaseStimulusParameters(10.0), ConstantStimuli())
                    ctrl_d = DashboardController(s_dual; presentation_mode = :dual_screen)
                    eng_d = SingleScreenMessageEngine(ctrl_d)
                    dash_d = MockSingleScreenDashboard(ctrl_d, Ref(true))
                    start_session!(s_dual)
                    run_when_started!(s_dual, eng_d, dash_d; report = :silent)
                    @test s_dual.state == FINISHED
                    @test isempty(eng_d.log)
                end
            end
        end

        @testset "Settings view exposes presentation_mode choices and applies before start" begin
            mktempdir() do dir
                cd(dir) do
                    write("settings.toml", "[display]\nfullscreen = false\n")
                    sections = PsychophysicsManager.dashboard_settings()
                    disp = only(filter(s -> s.name == "display", sections))
                    pm_row = only(filter(r -> r.key == "presentation_mode", disp.rows))
                    @test pm_row.value == "dual_screen"
                    @test pm_row.default == "dual_screen"
                    @test pm_row.choices == ["dual_screen", "single_screen"]

                    ctrl = DashboardController()
                    @test ctrl.presentation_mode === :dual_screen
                    @test PsychophysicsManager.edit_dashboard_setting!(
                        ctrl, "display", "presentation_mode", "single_screen")
                    @test ctrl.presentation_mode === :single_screen
                    @test !PsychophysicsManager.edit_dashboard_setting!(
                        ctrl, "display", "presentation_mode", "invalid_mode")
                    @test ctrl.presentation_mode === :single_screen

                    # Changing the setting while a session is running does not touch the active run
                    s_run = make_session()
                    start_session!(s_run)
                    PsychophysicsManager.bind_session!(ctrl, s_run)
                    @test PsychophysicsManager.edit_dashboard_setting!(
                        ctrl, "display", "presentation_mode", "dual_screen")
                    @test ctrl.presentation_mode === :single_screen
                end
            end
        end
    end
end
