# The views docked in the dashboard window. Each draws from the controller and
# from what the frame last reread from the session, and forwards what the operator
# does to a controller function; none of them changes a session itself.

label_width(dashboard::DashboardWindow) = 7.5f0 * ig.GetFontSize()

# A view's window. A view left in a window of its own when the dashboard was last closed
# returns into the dashboard, which takes its default arrangement again: the layout
# would reopen that window where it was, on a monitor since unplugged or under a
# desktop panel, out of reach. A view is dragged out for the sitting. The View menu
# opens and closes the views, which have no close button of their own.
function begin_view(dashboard::DashboardWindow, view::Symbol)
    shown = ig.Begin(view_title(view))
    dashboard.frames <= 2 && ig.GetWindowViewport() != ig.GetMainViewport() &&
        (dashboard.build_layout = true)
    return shown
end

# ── Browse ───────────────────────────────────────────────────────────────────

# Where a session is chosen: the templates, and the previous sessions with their data.
# Shown by a dashboard that runs its own sessions; one attached to a script's session
# has its session already.
function draw_browse_view!(dashboard::DashboardWindow)
    dashboard.show_browse[] || return nothing
    # The dashboard opens on it, once the docks have settled
    dashboard.frames == 3 && ig.SetNextWindowFocus()
    if begin_view(dashboard, :browse)
        controller = dashboard.controller
        if controller.lists_stale && (!is_running(controller) || paused_loop(controller))
            reread_lists!(dashboard)
        end
        ig.BeginDisabled(!action_state(controller).can_load)
        height = ig.GetContentRegionAvail().y
        if ig.BeginTabBar("browse_lists")
            if ig.BeginTabItem(ui_label(:start_templates) * "###templates")
                draw_entry_table!(dashboard, dashboard.templates, height)
                ig.EndTabItem()
            end
            if ig.BeginTabItem(ui_label(:start_sessions) * "###sessions", C_NULL,
                               dashboard.show_sessions ? ig.lib.ImGuiTabItemFlags_SetSelected : 0)
                draw_sessions_tab!(dashboard)
                ig.EndTabItem()
            end
            if ig.BeginTabItem(ui_label(:start_scenarios) * "###scenarios")
                draw_plan_tables!(dashboard)
                ig.EndTabItem()
            end
            dashboard.show_sessions = false
            ig.EndTabBar()
        end
        ig.EndDisabled()
        # Delete sets the chosen file aside, once confirmed
        ig.IsWindowFocused(ig.lib.ImGuiFocusedFlags_RootAndChildWindows) && !dashboard.typing &&
            ig.IsKeyPressed(ig.lib.ImGuiKey_Delete, false) &&
            controller.chosen !== nothing && isfile(controller.chosen) &&
            (dashboard.discard_path = controller.chosen)
    end
    ig.End()
    return nothing
end

# A modal question, answered by its button (`:confirm`) or by Cancel or Esc (`:cancel`);
# `nothing` while it waits
function confirmation(id::String, title::String, question::String, confirm::String)
    title = title * "###" * id
    ig.IsPopupOpen(title) || ig.OpenPopup(title)
    ig.BeginPopupModal(title, C_NULL, ig.lib.ImGuiWindowFlags_AlwaysAutoResize) ||
        return nothing
    ig.PushTextWrapPos(ig.GetFontSize() * 32)
    text(question)
    ig.PopTextWrapPos()
    ig.Spacing()
    answer = button(confirm, true; color = DANGER) ? :confirm : nothing
    ig.SameLine()
    (button(ui_label(:cancel), true) || ig.IsKeyPressed(ig.lib.ImGuiKey_Escape, false)) &&
        (answer = :cancel)
    answer === nothing || ig.CloseCurrentPopup()
    ig.EndPopup()
    return answer
end

# The confirmation a discard waits for, from Delete or a row's menu in Browse, or the
# Session menu
function draw_discard_confirmation!(dashboard::DashboardWindow)
    path = dashboard.discard_path
    path === nothing && return nothing
    answer = confirmation("discard", ui_label(:discard_title),
                          ui_label(:discard_question; file = basename(path)),
                          ui_label(:discard))
    answer === nothing && return nothing
    dashboard.discard_path = nothing
    answer === :confirm && discard_dashboard_file!(dashboard.controller, path)
    return nothing
end

# A Browse choice: asks before dropping a prepared session; sets a paused one aside
function choose_in_browse!(choose::Function, dashboard::DashboardWindow)
    controller = dashboard.controller
    prepared_session(controller) === nothing ? after_setting_aside!(choose, controller) :
                                               (dashboard.pending_choice = choose)
    return nothing
end

function draw_choice_confirmation!(dashboard::DashboardWindow)
    choose = dashboard.pending_choice
    choose === nothing && return nothing
    answer = confirmation("drop_prepared", ui_label(:drop_prepared_title),
                          ui_label(:drop_prepared_question), ui_label(:drop_prepared))
    answer === nothing && return nothing
    dashboard.pending_choice = nothing
    answer === :confirm && choose()
    return nothing
end

function draw_save_dataset_popup!(dashboard::DashboardWindow)
    dashboard.save_dataset_popup || return nothing
    title = ui_label(:save_dataset_title) * "###save_dataset"
    ig.IsPopupOpen(title) || ig.OpenPopup(title)
    ig.BeginPopupModal(title, C_NULL, ig.lib.ImGuiWindowFlags_AlwaysAutoResize) ||
        return nothing
    controller = dashboard.controller
    ig.SetNextItemWidth(18 * ig.GetFontSize())
    entered = ig.InputTextWithHint("##dataset_name", ui_label(:combine_name_hint),
                                   dashboard.dataset_buffer, length(dashboard.dataset_buffer),
                                   ig.lib.ImGuiInputTextFlags_EnterReturnsTrue)
    if dashboard.save_dataset_error !== nothing
        ig.PushTextWrapPos(ig.GetFontSize() * 32)
        colored_text(dashboard.save_dataset_error, SET_ASIDE_POINTS)
        ig.PopTextWrapPos()
    end
    ig.Spacing()
    named = !isempty(strip(buffer_text(dashboard.dataset_buffer)))
    saved_click = button(ui_label(:save_dataset), named; color = GO)
    if (entered && named) || saved_click
        if save_ticked_dataset!(controller, buffer_text(dashboard.dataset_buffer))
            fill_buffer!(dashboard.dataset_buffer, "")
            dashboard.save_dataset_popup = false
            dashboard.save_dataset_error = nothing
            ig.CloseCurrentPopup()
        else
            dashboard.save_dataset_error = controller.message
        end
    end
    ig.SameLine()
    if button(ui_label(:cancel), true) || ig.IsKeyPressed(ig.lib.ImGuiKey_Escape, false)
        dashboard.save_dataset_popup = false
        dashboard.save_dataset_error = nothing
        ig.CloseCurrentPopup()
    end
    ig.EndPopup()
    return nothing
end

function reread_lists!(dashboard::DashboardWindow)
    dashboard.controller.lists_stale = false
    try
        dashboard.templates = dashboard_templates()
        dashboard.entries = reread_library!(dashboard.controller)
        dashboard.entries_version += 1
        prune_session_cache!(dashboard.session_cache,
                             String[e.path for e in dashboard.entries if e.kind === :session])
        dashboard.plans = dashboard_plans()
        plan = dashboard.controller.plan
        dashboard.plan_runs = plan === nothing ? DashboardRunRow[] : dashboard_plan_runs(plan)
    catch err
        set_message!(dashboard.controller, sprint(showerror, err))
    end
    return nothing
end

filter_state_label(state::Union{Symbol, SessionState}) =
    state === :all ? ui_label(:filter_all_states) :
    state === :continuable ? ui_label(:filter_continuable) : state_label(state)

function draw_sessions_tab!(dashboard::DashboardWindow)
    draw_sessions_filter_bar!(dashboard)
    draw_more_filters!(dashboard)
    draw_series_table!(dashboard)
    ig.Separator()
    draw_ticked_bar!(dashboard)
    return nothing
end

function draw_sessions_filter_bar!(dashboard::DashboardWindow)
    filters = dashboard.filters
    spacing = unsafe_load(ig.GetStyle().ItemSpacing).x
    width = max((ig.GetContentRegionAvail().x - 4 * spacing) / 5f0, 5 * ig.GetFontSize())

    ig.SetNextItemWidth(width)
    exp_shown = isempty(filters.experiment) ? ui_label(:filter_all_experiments) : filters.experiment
    if ig.BeginCombo("##filter_experiment", exp_shown)
        ig.Selectable(ui_label(:filter_all_experiments), isempty(filters.experiment)) &&
            (filters.experiment = "")
        for exp in dashboard_entry_experiments(dashboard.entries)
            ig.Selectable(exp, exp == filters.experiment) && (filters.experiment = exp)
        end
        ig.EndCombo()
    end
    tooltip(:tip_filter_experiment)

    ig.SameLine()
    ig.SetNextItemWidth(width)
    part_shown = isempty(filters.participant) ? ui_label(:start_all_participants) : filters.participant
    if ig.BeginCombo("##filter_participant", part_shown)
        ig.Selectable(ui_label(:start_all_participants), isempty(filters.participant)) &&
            (filters.participant = "")
        for p in dashboard_entry_participants(dashboard.entries)
            ig.Selectable(p, p == filters.participant) && (filters.participant = p)
        end
        ig.EndCombo()
    end
    tooltip(:tip_filter_participant)

    ig.SameLine()
    ig.SetNextItemWidth(width)
    if ig.InputTextWithHint("##filter_tags", ui_label(:filter_tags_hint),
                            dashboard.filter_tags_buffer, length(dashboard.filter_tags_buffer))
        filters.tags = buffer_text(dashboard.filter_tags_buffer)
    end
    tooltip(:tip_filter_tags)

    ig.SameLine()
    ig.SetNextItemWidth(width)
    if ig.BeginCombo("##filter_state", filter_state_label(filters.state))
        for choice in Any[:all, :continuable, instances(SessionState)...]
            ig.Selectable(filter_state_label(choice), filters.state === choice) &&
                (filters.state = choice)
        end
        ig.EndCombo()
    end
    tooltip(:tip_filter_state)

    ig.SameLine()
    ig.SetNextItemWidth(max(ig.GetContentRegionAvail().x, 5 * ig.GetFontSize()))
    if ig.InputTextWithHint("##filter_text", ui_label(:filter_text_hint),
                            dashboard.filter_text_buffer, length(dashboard.filter_text_buffer))
        filters.text = buffer_text(dashboard.filter_text_buffer)
    end
    tooltip(:tip_filter_text)
    return nothing
end

function draw_more_filters!(dashboard::DashboardWindow)
    ig.CollapsingHeader(ui_label(:more_filters) * "###more_filters") || return nothing
    filters = dashboard.filters
    controller = dashboard.controller
    style = unsafe_load(ig.GetStyle())
    spacing = style.ItemSpacing.x
    width = max((ig.GetContentRegionAvail().x - 4 * spacing) / 5f0, 5 * ig.GetFontSize())

    ig.SetNextItemWidth(width)
    method_shown = isempty(filters.method) ? ui_label(:filter_all_methods) : filters.method
    if ig.BeginCombo("##filter_method", method_shown)
        ig.Selectable(ui_label(:filter_all_methods), isempty(filters.method)) &&
            (filters.method = "")
        for m in dashboard_entry_methods(dashboard.entries)
            ig.Selectable(m, m == filters.method) && (filters.method = m)
        end
        ig.EndCombo()
    end
    tooltip(:tip_filter_method)

    ig.SameLine()
    ig.SetNextItemWidth(width)
    stim_shown = isempty(filters.stimulus) ? ui_label(:filter_all_stimuli) : filters.stimulus
    if ig.BeginCombo("##filter_stimulus", stim_shown)
        ig.Selectable(ui_label(:filter_all_stimuli), isempty(filters.stimulus)) &&
            (filters.stimulus = "")
        for s in dashboard_entry_stimuli(dashboard.entries)
            ig.Selectable(s, s == filters.stimulus) && (filters.stimulus = s)
        end
        ig.EndCombo()
    end
    tooltip(:tip_filter_stimulus)

    ig.SameLine()
    from_valid = last(parse_filter_date(filters.from))
    from_valid || ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
    ig.SetNextItemWidth(width)
    if ig.InputTextWithHint("##filter_from", ui_label(:filter_from_hint),
                            dashboard.filter_from_buffer, length(dashboard.filter_from_buffer))
        filters.from = buffer_text(dashboard.filter_from_buffer)
    end
    from_valid || ig.PopStyleColor()
    tooltip(:tip_filter_from)

    ig.SameLine()
    to_valid = last(parse_filter_date(filters.to))
    to_valid || ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
    ig.SetNextItemWidth(width)
    if ig.InputTextWithHint("##filter_to", ui_label(:filter_to_hint),
                            dashboard.filter_to_buffer, length(dashboard.filter_to_buffer))
        filters.to = buffer_text(dashboard.filter_to_buffer)
    end
    to_valid || ig.PopStyleColor()
    tooltip(:tip_filter_to)

    ig.SameLine()
    param_valid = last(parse_filter_parameter(filters.parameter))
    param_valid || ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
    ig.SetNextItemWidth(max(ig.GetContentRegionAvail().x, 5 * ig.GetFontSize()))
    if ig.InputTextWithHint("##filter_parameter", ui_label(:filter_parameter_hint),
                            dashboard.filter_parameter_buffer,
                            length(dashboard.filter_parameter_buffer))
        filters.parameter = buffer_text(dashboard.filter_parameter_buffer)
    end
    param_valid || ig.PopStyleColor()
    tooltip(:tip_filter_parameter)

    # The optional combining checks that form series and govern Save as Dataset
    ig.AlignTextToFramePadding()
    text(ui_label(:combine_checks))
    tooltip(:tip_combine_checks)
    for check in COMBINING_CHECKS
        label = ui_label(Symbol("check_", check))
        ig.SameLine()
        ig.GetContentRegionAvail().x < ig.CalcTextSize(label).x + ig.GetFrameHeight() +
                                       style.ItemInnerSpacing.x && ig.NewLine()
        on = Ref(check in controller.checks)
        ig.Checkbox(label, on) && set_combining_check!(controller, check, on[])
        tooltip(Symbol("tip_check_", check))
    end
    return nothing
end

function draw_series_table!(dashboard::DashboardWindow)
    controller = dashboard.controller
    series = dashboard_series_rows(dashboard.entries, dashboard.filters, controller.checks)
    datasets = dashboard_dataset_rows(dashboard.entries, dashboard.filters)

    bar_height = ig.GetFrameHeightWithSpacing() + unsafe_load(ig.GetStyle().ItemSpacing).y
    height = max(ig.GetContentRegionAvail().y - bar_height, 4 * ig.GetFrameHeightWithSpacing())

    if isempty(series) && isempty(datasets)
        if ig.BeginChild("sessions_empty", (0f0, Float32(height)))
            if isempty(dashboard.entries)
                wrapped_text(ui_label(:start_no_sessions; directory = resolve_data_dir());
                             color = DIM_TEXT)
            else
                wrapped_text(ui_label(:start_no_matching_sessions); color = DIM_TEXT)
            end
        end
        ig.EndChild()
        return nothing
    end

    columns = ((:column_last_run, 1.3f0), (:column_participant, 0.8f0),
               (:column_experiment, 1.0f0), (:column_variables, 1.4f0),
               (:column_repetitions, 0.45f0), (:column_trials, 0.6f0),
               (:column_state, 0.9f0))
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    ig.BeginTable("sessions", length(columns) + 1, flags, (0f0, Float32(height))) ||
        return nothing
    ig.TableSetupScrollFreeze(0, 1)
    ig.TableSetupColumn("##tick", ig.lib.ImGuiTableColumnFlags_WidthFixed, ig.GetFrameHeight())
    for (column, weight) in columns
        ig.TableSetupColumn(ui_label(column), ig.lib.ImGuiTableColumnFlags_WidthStretch, weight)
    end
    ig.TableHeadersRow()

    for srow in series
        ig.PushID(srow.key)
        ig.TableNextRow()
        ig.TableNextColumn()
        tick_state = series_tick_state(srow, controller.ticked)
        checked = Ref(tick_state === :all)
        mixed = tick_state === :some
        mixed && ig.PushItemFlag(Int(ig.lib.ImGuiItemFlags_MixedValue), true)
        changed = ig.Checkbox("##tick", checked)
        mixed && ig.PopItemFlag()
        changed && tick_series!(controller, srow, checked[])
        tooltip(mixed ? :tip_tick_series_some : :tip_tick_series)

        ig.TableNextColumn()
        node_flags = ig.lib.ImGuiTreeNodeFlags_SpanAllColumns |
                     ig.lib.ImGuiTreeNodeFlags_OpenOnArrow |
                     ig.lib.ImGuiTreeNodeFlags_OpenOnDoubleClick |
                     ig.lib.ImGuiTreeNodeFlags_FramePadding |
                     ig.lib.ImGuiTreeNodeFlags_AllowOverlap |
                     ig.lib.ImGuiTreeNodeFlags_NoTreePushOnOpen
        if controller.chosen !== nothing && any(s -> s.path == controller.chosen, srow.sessions)
            node_flags |= ig.lib.ImGuiTreeNodeFlags_Selected
        end
        node_label = (isempty(srow.last_run) ? "—" : srow.last_run) * "##series"
        opened = ig.TreeNodeEx(node_label, node_flags)
        if ig.IsItemClicked(ig.lib.ImGuiMouseButton_Left) && !ig.IsItemToggledOpen()
            chosen_series = srow
            choose_in_browse!(dashboard) do
                choose_series!(controller, chosen_series)
            end
        end
        tooltip(:tip_choose_series)

        ig.TableNextColumn(); text(srow.participant)
        ig.TableNextColumn(); text(srow.experiment)
        ig.TableNextColumn(); text(srow.variables)
        isempty(srow.variables) || tooltip(srow.variables)
        ig.TableNextColumn(); text(string(srow.repetitions))
        ig.TableNextColumn(); text(srow.trials)
        ig.TableNextColumn(); text(srow.state)

        if opened
            for erow in srow.sessions
                ig.PushID(erow.path)
                ig.TableNextRow()
                ig.TableNextColumn()
                ticked = Ref(erow.path in controller.ticked)
                ig.Checkbox("##tick", ticked) && tick_session!(controller, erow.path, ticked[])
                tooltip(:tip_tick_session)

                ig.TableNextColumn()
                started = isempty(erow.started) ? "—" : erow.started
                if ig.Selectable("    " * started * "##session", erow.path == controller.chosen,
                                 ig.lib.ImGuiSelectableFlags_SpanAllColumns |
                                 ig.lib.ImGuiSelectableFlags_AllowOverlap)
                    path = erow.path
                    choose_in_browse!(dashboard) do
                        open_previous_session!(controller, path)
                    end
                end
                tooltip(:tip_choose_session)
                if ig.BeginPopupContextItem("entry_menu")
                    ig.MenuItem(ui_label(:discard) * "…") && (dashboard.discard_path = erow.path)
                    ig.EndPopup()
                end

                ig.TableNextColumn(); text(erow.participants)
                ig.TableNextColumn(); text(erow.experiment)
                ig.TableNextColumn(); text(erow.name)
                isempty(erow.name) || tooltip(erow.name)
                ig.TableNextColumn(); text("—")
                ig.TableNextColumn(); text(erow.trials)
                ig.TableNextColumn(); text(erow.state)
                ig.PopID()
            end
        end
        ig.PopID()
    end

    for drow in datasets
        ig.PushID(drow.path)
        ig.TableNextRow()
        ig.TableNextColumn()
        ig.TableNextColumn()
        started = isempty(drow.started) ? "—" : drow.started
        if ig.Selectable(started * "##dataset", drow.path == controller.chosen,
                         ig.lib.ImGuiSelectableFlags_SpanAllColumns |
                         ig.lib.ImGuiSelectableFlags_AllowOverlap)
            path = drow.path
            choose_in_browse!(dashboard) do
                choose_setup!(controller, path)
            end
        end
        tooltip(:tip_choose_dataset)
        if ig.BeginPopupContextItem("entry_menu")
            ig.MenuItem(ui_label(:discard) * "…") && (dashboard.discard_path = drow.path)
            ig.EndPopup()
        end

        ig.TableNextColumn(); text(drow.participants)
        ig.TableNextColumn(); text(drow.experiment)
        ig.TableNextColumn(); text(drow.name)
        isempty(drow.name) || tooltip(drow.name)
        ig.TableNextColumn(); text("—")
        ig.TableNextColumn(); text(drow.trials)
        ig.TableNextColumn(); text(drow.state)
        ig.PopID()
    end

    ig.EndTable()
    return nothing
end

function draw_ticked_bar!(dashboard::DashboardWindow)
    controller = dashboard.controller
    has_ticks = !isempty(controller.ticked)
    ig.AlignTextToFramePadding()
    text(ui_label(:ticked_count; count = length(controller.ticked)))
    ig.SameLine()
    button(ui_label(:clear_ticks), has_ticks) && clear_ticks!(controller)
    tooltip(:tip_clear_ticks)
    ig.SameLine()
    if button(ui_label(:save_as_dataset), has_ticks; color = GO)
        dashboard.save_dataset_popup = true
        dashboard.save_dataset_error = nothing
    end
    tooltip(:tip_save_dataset)
    return nothing
end

# One template per row. A click prepares a new session from it.
function draw_entry_table!(dashboard::DashboardWindow, rows::Vector{DashboardEntryRow},
                           height::Real)
    controller = dashboard.controller
    if isempty(rows)
        wrapped_text(ui_label(:start_no_templates; directory = resolve_templates_dir());
                     color = DIM_TEXT)
        return nothing
    end
    columns = [:column_name, :column_experiment, :column_method, :column_stimulus]
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    ig.BeginTable("templates", length(columns), flags, (0f0, Float32(height))) ||
        return nothing
    ig.TableSetupScrollFreeze(0, 1)
    foreach(column -> ig.TableSetupColumn(ui_label(column)), columns)
    ig.TableHeadersRow()
    for row in rows
        ig.PushID(row.path)
        ig.TableNextRow()
        ig.TableNextColumn()
        cells = [row.name, row.experiment, row.method, row.stimulus]
        if ig.Selectable(first(cells), row.path == controller.chosen,
                         ig.lib.ImGuiSelectableFlags_SpanAllColumns |
                         ig.lib.ImGuiSelectableFlags_AllowOverlap)
            path = row.path
            choose_in_browse!(dashboard) do
                choose_setup!(controller, path)
            end
        end
        tooltip(:tip_choose_template)
        for cell in cells[2:end]
            ig.TableNextColumn()
            text(cell)
        end
        ig.PopID()
    end
    ig.EndTable()
    return nothing
end

# The scenario plans, and below them the runs of the one chosen. A click on a plan
# prepares its next run
function draw_plan_tables!(dashboard::DashboardWindow)
    controller = dashboard.controller
    if isempty(dashboard.plans)
        wrapped_text(ui_label(:start_no_plans; directory = resolve_templates_dir());
                     color = DIM_TEXT)
        return nothing
    end
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    height = ig.GetContentRegionAvail().y
    plans_height = controller.plan === nothing ? height :
        min(0.4f0 * height, (length(dashboard.plans) + 1.5f0) * ig.GetFrameHeightWithSpacing())
    if ig.BeginTable("plans", 3, flags, (0f0, Float32(plans_height)))
        ig.TableSetupScrollFreeze(0, 1)
        foreach(column -> ig.TableSetupColumn(ui_label(column)),
                (:column_name, :column_runs, :column_next))
        ig.TableHeadersRow()
        for row in dashboard.plans
            ig.PushID(row.path)
            ig.TableNextRow()
            ig.TableNextColumn()
            if ig.Selectable(row.name, row.path == controller.plan,
                             ig.lib.ImGuiSelectableFlags_SpanAllColumns |
                             ig.lib.ImGuiSelectableFlags_AllowOverlap)
                path = row.path
                choose_in_browse!(dashboard) do
                    choose_scenario!(controller, path)
                    controller.lists_stale = true
                end
            end
            tooltip(:tip_choose_plan)
            ig.TableNextColumn()
            text(row.runs)
            ig.TableNextColumn()
            row.problem ? colored_text(row.next, SET_ASIDE_POINTS) : text(row.next)
            ig.PopID()
        end
        ig.EndTable()
    end
    (controller.plan === nothing || isempty(dashboard.plan_runs)) && return nothing
    ig.Spacing()
    columns = (:column_trial, :column_run, :column_participant, :column_setup, :column_file,
               :column_state)
    ig.BeginTable("plan_runs", length(columns), flags, (0f0, ig.GetContentRegionAvail().y)) ||
        return nothing
    ig.TableSetupScrollFreeze(0, 1)
    foreach(column -> ig.TableSetupColumn(ui_label(column)), columns)
    ig.TableHeadersRow()
    in_hand = controller.plan_run === nothing ? nothing : controller.plan_run.row.id
    for row in dashboard.plan_runs
        ig.TableNextRow()
        row.id == in_hand &&
            ig.TableSetBgColor(ig.lib.ImGuiTableBgTarget_RowBg1, ig.GetColorU32(ig.lib.ImGuiCol_Header))
        for cell in (row.position, row.id, row.participant, row.setup, row.file, row.state)
            ig.TableNextColumn()
            text(cell)
        end
    end
    ig.EndTable()
    return nothing
end

# Who the next session is for: the session prepared and not started, or the new one
# Start New Session runs
function draw_participant_choice!(dashboard::DashboardWindow, width::Real)
    controller = dashboard.controller
    # The field follows the participant a choice in Browse sets, except while typed in
    dashboard.typing || buffer_text(dashboard.participant_buffer) == controller.participant ||
        fill_buffer!(dashboard.participant_buffer, controller.participant)
    text(ui_label(:participant))
    ig.SameLine(Float32(width))
    ig.SetNextItemWidth(-2.2f0 * ig.GetFontSize())
    ig.InputText("##participant", dashboard.participant_buffer,
                 length(dashboard.participant_buffer)) &&
        set_dashboard_participant!(controller, buffer_text(dashboard.participant_buffer))
    ig.SameLine()
    if ig.BeginCombo("##participants", "", ig.lib.ImGuiComboFlags_NoPreview)
        controller.lists_stale && !is_running(controller) && reread_lists!(dashboard)
        for participant in dashboard_participants(dashboard.entries)
            if ig.Selectable(participant, participant == controller.participant)
                set_dashboard_participant!(controller, participant)
                fill_buffer!(dashboard.participant_buffer, participant)
            end
        end
        ig.EndCombo()
    end
    tooltip(:tip_participant)
    return nothing
end

# The parameters of the session in hand, or of the new session prepared from it once it
# has ended (`parameters_session`): its settings and every stimulus parameter, edited in
# place, and Save as Template. With two or more sessions ticked and no session running,
# shows the ticked sessions together and relabels all of them via `edit_ticked_labels!`.
function draw_parameters_view!(dashboard::DashboardWindow)
    dashboard.show_parameters[] || return nothing
    if begin_view(dashboard, :parameters)
        controller = dashboard.controller
        if length(controller.ticked) >= 2 && !is_running(controller)
            controller.lists_stale && reread_lists!(dashboard)
            if length(controller.ticked) >= 2
                draw_ticked_parameters!(dashboard)
                ig.End()
                return nothing
            end
        end
        session = parameters_session(controller)
        if session === nothing
            colored_text(no_session_text(), DIM_TEXT)
        else
            forget_edits_of_other_sessions!(dashboard, session)
            editable = can_edit_parameters(controller)
            # A session saved with parameters its stimulus refuses still shows its data
            rows = try
                dashboard_setup_rows(session; declared = connected_engine(controller))
            catch err
                err isa ArgumentError || rethrow()
                err
            end
            if rows isa ArgumentError
                wrapped_text(ui_label(:parameters_unreadable; error = rows.msg);
                             color = SET_ASIDE_POINTS)
                ig.End()
                return nothing
            end
            draw_new_session_note(controller)
            # The tables scroll above a bar that stays in sight
            style = unsafe_load(ig.GetStyle())
            lines = parameters_bar_wraps(controller, style) ? 2 : 1
            bar = lines * ig.GetFrameHeightWithSpacing() + style.ItemSpacing.y
            if ig.BeginChild("parameter_tables", (0f0, -bar))
                for (id, label, table, color) in (
                        ("experiment", :experiment_settings, rows.experiment, SECTION_BAR),
                        ("stimulus", :stimulus_parameters, rows.stimulus, SECTION_BAR_STIMULUS),
                        ("messages", :participant_messages, rows.messages, SECTION_BAR_MESSAGES))
                    section_bar(ui_label(label) * "###" * id; color) &&
                        draw_parameter_table!(dashboard, id, table, editable)
                end
            end
            ig.EndChild()
            ig.Separator()
            draw_parameters_bar!(dashboard)
        end
    end
    ig.End()
    return nothing
end

function draw_ticked_parameters!(dashboard::DashboardWindow)
    controller = dashboard.controller
    by_path = Dict(e.path => e for e in dashboard.entries)
    selected = LibraryEntry[by_path[p] for p in controller.ticked if haskey(by_path, p)]
    if length(selected) < 2
        colored_text(no_session_text(), DIM_TEXT)
        return nothing
    end
    forget_edits_for_ticked!(dashboard, controller.ticked)
    rows = ticked_parameter_rows(selected)
    wrapped_text(ui_label(:ticked_parameters_note; count = length(selected)); color = DIM_TEXT)
    ig.Spacing()
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    ig.BeginTable("ticked_parameters", 2, flags, (0f0, ig.GetContentRegionAvail().y)) ||
        return nothing
    for row in rows
        ig.TableNextRow()
        ig.TableNextColumn()
        text(row.label)
        row.tooltip !== nothing && tooltip(row.tooltip)
        ig.TableNextColumn()
        if row.key !== nothing
            draw_ticked_parameter_field!(dashboard, row)
        else
            row.differs ? colored_text(row.value, PASTEL_AMBER) : text(row.value)
            row.tooltip !== nothing && tooltip(row.tooltip)
        end
    end
    ig.EndTable()
    return nothing
end

function draw_ticked_parameter_field!(dashboard::DashboardWindow, row::ParameterRow)
    controller = dashboard.controller
    key = row.key
    buffer = get!(() -> text_buffer(row.edit; size = 4096), dashboard.edit_buffers, key)
    refused = key in dashboard.refused_edits
    dashboard.editing_key != key && !refused && buffer_text(buffer) != row.edit &&
        fill_buffer!(buffer, row.edit)
    hint = key == "experiment_name" && row.differs ? row.value :
           key == "tags" ? ui_label(:ticked_tags_hint) :
           key == "comment" ? ui_label(:ticked_comment_hint) : ""
    pushed_colors = 0
    if refused
        ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
        pushed_colors += 1
    elseif row.differs
        ig.PushStyleColor(ig.lib.ImGuiCol_Text, PASTEL_AMBER)
        ig.PushStyleColor(ig.lib.ImGuiCol_TextDisabled, PASTEL_AMBER)
        pushed_colors += 2
    end
    ig.SetNextItemWidth(-1f0)
    ig.InputTextWithHint("##ticked_" * key, hint, buffer, length(buffer))
    pushed_colors > 0 && ig.PopStyleColor(pushed_colors)
    if ig.IsItemActive()
        dashboard.editing_key = key
    elseif dashboard.editing_key == key
        dashboard.editing_key = nothing
    end
    if submitted(refused)
        if edit_ticked_labels!(controller, key, buffer_text(buffer))
            delete!(dashboard.refused_edits, key)
            key == "comment" && fill_buffer!(buffer, "")
        else
            push!(dashboard.refused_edits, key)
        end
    end
    tip = ui_label(:tip_ticked_edit)
    tooltip(row.tooltip === nothing ? tip : row.tooltip * "\n\n" * tip)
    return nothing
end

function forget_edits_for_ticked!(dashboard::DashboardWindow, ticked::Vector{String})
    dashboard.edit_ticked == ticked && return nothing
    empty!(dashboard.edit_buffers)
    empty!(dashboard.refused_edits)
    empty!(dashboard.typed_previews)
    dashboard.editing_key = nothing
    dashboard.edit_session = nothing
    dashboard.edit_stimulus = nothing
    dashboard.edit_ticked = copy(ticked)
    return nothing
end

function draw_parameter_table!(dashboard::DashboardWindow, id::String,
                               rows::Vector{ParameterRow}, editable::Bool)
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_Resizable
    ig.BeginTable(id, 2, flags) || return nothing
    # Units and the task type change whenever no loop runs: they change what a report
    # shows and fits, not the record
    reporting = can_edit_reporting(dashboard.controller)
    previewable = can_preview(dashboard.controller)
    for row in rows
        ig.TableNextRow()
        ig.TableNextColumn()
        key = row.key
        preview = key !== nothing && startswith(key, "preview.")
        preview ? colored_text(row.label, DIM_TEXT) : text(row.label)
        row.tooltip !== nothing && tooltip(row.tooltip)
        ig.TableNextColumn()
        if preview
            previewable ? draw_preview_field!(dashboard, row) : colored_text(row.value, DIM_TEXT)
        else
            field = key !== nothing && (reporting_key(key) ? reporting : editable)
            if field
                draw_parameter_field!(dashboard, row)
            else
                row.differs ? colored_text(row.value, PASTEL_AMBER) :
                row.source !== nothing ? colored_text(row.value, DIM_TEXT) : text(row.value)
                row.tooltip !== nothing && tooltip(row.tooltip)
            end
        end
    end
    ig.EndTable()
    return nothing
end

# One parameter's edit field. It shows the parameter's value, except while it is
# typed in, or holds a value that was refused, which stays to be corrected
function draw_parameter_field!(dashboard::DashboardWindow, row::ParameterRow)
    controller = dashboard.controller
    key = row.key
    if key in ("feedback", "messages.instructions")
        on = Ref(row.edit == "yes")
        ig.Checkbox("##" * key, on) &&
            edit_dashboard_parameter!(controller, key, on[] ? "yes" : "no")
        return nothing
    elseif !isempty(row.choices)
        row.unset && ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
        ig.SetNextItemWidth(-1f0)
        if ig.BeginCombo("##" * key, row.value)
            for (shown, value) in row.choices
                ig.Selectable(shown * "##" * value, shown == row.value) && shown != row.value &&
                    edit_dashboard_parameter!(controller, key, value)
            end
            ig.EndCombo()
        end
        row.unset && ig.PopStyleColor()
        tip = ui_label(choice_tip(key))
        tooltip(row.tooltip === nothing ? tip : row.tooltip * "\n\n" * tip)
        return nothing
    end
    buffer = get!(() -> text_buffer(row.edit; size = 4096), dashboard.edit_buffers, key)
    # Refused values and settings still to be given are marked alike
    refused = key in dashboard.refused_edits || row.unset
    dashboard.editing_key != key && !refused && buffer_text(buffer) != row.edit &&
        fill_buffer!(buffer, row.edit)
    dim = row.source !== nothing
    dim && ig.PushStyleColor(ig.lib.ImGuiCol_Text, DIM_TEXT)
    refused && ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
    ig.SetNextItemWidth(-1f0)
    if key in ("messages.break_text", "messages.closing_text")
        ig.InputTextMultiline("##" * key, buffer, length(buffer),
                              (-1f0, 3.5f0 * ig.GetTextLineHeightWithSpacing()))
    else
        ig.InputText("##" * key, buffer, length(buffer))
    end
    refused && ig.PopStyleColor()
    dim && ig.PopStyleColor()
    if ig.IsItemActive()
        dashboard.editing_key = key
    elseif dashboard.editing_key == key
        dashboard.editing_key = nothing
    end
    if submitted(refused)
        edit_dashboard_parameter!(controller, key, buffer_text(buffer)) ?
            delete!(dashboard.refused_edits, key) : push!(dashboard.refused_edits, key)
    end
    tooltip(:tip_edit_parameter)
    return nothing
end

# A value for the preview only, drawn grey: the design or the method sets it during the
# session. It starts at the design's first level and follows it until typed in.
function draw_preview_field!(dashboard::DashboardWindow, row::ParameterRow)
    key = row.key
    buffer = get!(() -> text_buffer(row.edit; size = 256), dashboard.edit_buffers, key)
    dashboard.editing_key != key && !(key in dashboard.typed_previews) &&
        buffer_text(buffer) != row.edit && fill_buffer!(buffer, row.edit)
    ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, PREVIEW_FIELD)
    ig.PushStyleColor(ig.lib.ImGuiCol_Text, DIM_TEXT)
    ig.SetNextItemWidth(-1f0)
    ig.InputText("##" * key, buffer, length(buffer))
    ig.PopStyleColor(2)
    ig.IsItemEdited() && push!(dashboard.typed_previews, key)
    if ig.IsItemActive()
        dashboard.editing_key = key
    elseif dashboard.editing_key == key
        dashboard.editing_key = nothing
    end
    tooltip(:tip_preview_value)
    return nothing
end

# Whether the template name field, beside the buttons, would show only a few letters
function parameters_bar_wraps(controller::DashboardController, style)
    button_width(key) = ig.CalcTextSize(ui_label(key)).x + 2 * style.FramePadding.x
    used = button_width(:preview) + style.ItemSpacing.x
    preview_open(controller) && (used += button_width(:close_preview) + style.ItemSpacing.x)
    field_width = ig.GetContentRegionAvail().x - used -
                  button_width(:save_template) - style.ItemSpacing.x
    return field_width < 12 * ig.GetFontSize()
end

# Preview (and Close Preview while open), then Save as Template, on a new line if narrow
function draw_parameters_bar!(dashboard::DashboardWindow)
    controller = dashboard.controller
    style = unsafe_load(ig.GetStyle())
    wraps = parameters_bar_wraps(controller, style)
    if button(ui_label(:preview), can_preview(controller); color = GO)
        values = Dict(chop(key; head = length("preview."), tail = 0) => buffer_text(buffer)
                      for (key, buffer) in dashboard.edit_buffers if startswith(key, "preview."))
        preview_dashboard_stimulus!(controller, values)
    end
    tooltip(:tip_preview)
    if preview_open(controller)
        ig.SameLine()
        button(ui_label(:close_preview), can_preview(controller)) && close_preview!(controller)
        tooltip(:tip_close_preview)
    end
    wraps || ig.SameLine()
    save_width = ig.CalcTextSize(ui_label(:save_template)).x + 2 * style.FramePadding.x
    ig.SetNextItemWidth(max(ig.GetContentRegionAvail().x - save_width - style.ItemSpacing.x,
                            4 * ig.GetFontSize()))
    ig.InputTextWithHint("##template", ui_label(:template_name), dashboard.template_buffer,
                         length(dashboard.template_buffer))
    ig.SameLine()
    if button(ui_label(:save_template), true)
        save_dashboard_template!(controller, buffer_text(dashboard.template_buffer)) &&
            fill_buffer!(dashboard.template_buffer, "")
    end
    tooltip(:tip_save_template)
    return nothing
end

# Once the session has ended, says that edits go to a new session
function draw_new_session_note(controller)
    prepared = prepared_session(controller)
    prepared === nothing &&
        !(can_edit_parameters(controller) && controller.session.state != READY) && return nothing
    participant = something(prepared, controller.session).participant_id
    notes = (ui_label(:parameters_prepared; participant), ui_label(:parameters_edit_prepares))
    shown = prepared === nothing ? notes[2] : notes[1]
    wrapped_text(shown; color = prepared === nothing ? DIM_TEXT : KEYS_TEXT)
    tooltip(prepared === nothing ? :tip_parameters_edit_prepares : :tip_parameters_prepared)
    # The first change turns one note into the other; both take the height of the
    # taller, so the lines below do not move under the pointer between two clicks
    width = ig.GetContentRegionAvail().x
    height(note) = ig.CalcTextSize(note, C_NULL, false, width).y
    missing_height = maximum(height, notes) - height(shown)
    spacing = unsafe_load(ig.GetStyle().ItemSpacing).y
    missing_height > 0 && ig.Dummy(ig.ImVec2(0f0, max(0f0, missing_height - spacing)))
    ig.Spacing()
    return nothing
end

choice_tip(key::AbstractString) =
    key == "stimulus" ? :tip_stimulus :
    key == "method" ? :tip_method : key == "task" ? :tip_task :
    key == "variable.new" ? :tip_add_variable :
    startswith(key, "variable.") ? :tip_variable :
    key == "messages.break_waits_for" ? :tip_break_waits_for : :tip_dependent

# Edits belong to the session they were typed for
function forget_edits_of_other_sessions!(dashboard::DashboardWindow, session::SessionContext)
    stim = stimulus_name(session.stim_par)
    if dashboard.edit_ticked === nothing &&
       dashboard.edit_session == session.id && dashboard.edit_stimulus == stim
        return nothing
    end
    empty!(dashboard.edit_buffers)
    empty!(dashboard.refused_edits)
    empty!(dashboard.typed_previews)
    dashboard.editing_key = nothing
    dashboard.edit_session = session.id
    dashboard.edit_stimulus = stim
    dashboard.edit_ticked = nothing
    return nothing
end

# ── Control ──────────────────────────────────────────────────────────────────

function draw_control_view!(dashboard::DashboardWindow)
    dashboard.show_control[] || return nothing
    if begin_view(dashboard, :control)
        controller = dashboard.controller
        available = action_state(controller)
        draw_session_status(dashboard)
        draw_session_controls!(dashboard, available)
        session = controller.session
        if session !== nothing && session.shown_message !== nothing
            ig.Separator()
            draw_shown_message!(dashboard, session.shown_message)
        end
        if session !== nothing
            ig.Separator()
            draw_comments!(dashboard, session)
        end
        ig.Separator()
        draw_key_guide(dashboard)
    end
    ig.End()
    return nothing
end

# The operator's comments on the session in hand, the latest first, under a field that
# adds one
function draw_comments!(dashboard::DashboardWindow, session::SessionContext)
    buffer = dashboard.comment_buffer
    ig.SetNextItemWidth(-4.5f0 * ig.GetFontSize())
    entered = ig.InputTextWithHint("##comment", ui_label(:comment_hint), buffer,
                                   length(buffer), ig.lib.ImGuiInputTextFlags_EnterReturnsTrue)
    tooltip(:tip_comment)
    ig.SameLine()
    added = button(ui_label(:add_comment), !isempty(strip(buffer_text(buffer))))
    (entered || added) && add_dashboard_comment!(dashboard.controller, buffer_text(buffer)) &&
        fill_buffer!(buffer, "")
    isempty(session.comments) && return nothing
    lines = min(length(session.comments), 3)
    if ig.BeginChild("comments", (0f0, (lines + 0.5f0) * ig.GetTextLineHeightWithSpacing()),
                     ig.lib.ImGuiChildFlags_Borders)
        for comment in Iterators.reverse(session.comments)
            wrapped_text(Libc.strftime("%H:%M", comment.time) *
                         (comment.trial === nothing ? "" : " #$(comment.trial)") *
                         "  " * comment.text)
        end
    end
    ig.EndChild()
    return nothing
end

# What the participant is shown, under the controls that end it: the text scrolls in a
# few lines of its own, so long instructions do not push Continue out of the view
function draw_shown_message!(dashboard::DashboardWindow, message::ParticipantMessage)
    colored_text(ui_label(Symbol("shown_", message.kind)), KEYS_TEXT)
    message.dismissible && colored_text(ui_label(:message_dismiss_keys), DIM_TEXT)
    if message.kind in (:instructions, :closing)
        button(ui_label(:end_message), true; color = GO) &&
            end_dashboard_message!(dashboard.controller)
        tooltip(:tip_end_message)
    end
    if ig.BeginChild("shown_message", (0f0, 5.5f0 * ig.GetTextLineHeightWithSpacing()),
                     ig.lib.ImGuiChildFlags_Borders)
        wrapped_text(message.text)
    end
    ig.EndChild()
    return nothing
end

function draw_session_status(dashboard::DashboardWindow)
    controller = dashboard.controller
    session = controller.session
    width = label_width(dashboard)
    # Before a session starts, and after it has ended, the participant is the next
    # session's, and is chosen here, unless a scenario's plan names them
    if can_choose_participant(controller)
        draw_participant_choice!(dashboard, width)
    else
        field(ui_label(:participant), dashboard_participant_text(session), width)
    end
    # The state, and beside it the trials on a bar, or as a count when none are planned
    status = dashboard_status_text(session)
    colored_text(status, session === nothing ? DIM_TEXT : STATE_COLORS[session.state])
    session === nothing || draw_progress(session, status, width)
    isempty(dashboard.controller.message) ||
        wrapped_text(dashboard.controller.message; color = DIM_TEXT)
    return nothing
end

function draw_progress(session::SessionContext, status::AbstractString, width::Real)
    spacing = unsafe_load(ig.GetStyle().ItemSpacing).x
    ig.SameLine(max(Float32(width), ig.CalcTextSize(status).x + 2 * spacing))
    progress = format_dashboard_progress(session)
    total = planned_valid_trials(session)
    if total === nothing
        text(progress)
    else
        valid = count(t -> t.is_valid, session.history)
        done = clamp(valid / max(total, 1), 0, 1)
        ig.PushStyleColor(ig.lib.ImGuiCol_PlotHistogram, PROGRESS)
        ig.ProgressBar(Float32(done), (-1f0, 0f0), progress)
        ig.PopStyleColor()
    end
    return nothing
end

# One row of buttons, which ones by the state of the session (`control_buttons`)
const CONTROL_BUTTONS = Dict(
    :start     => (:start_session, :can_start, :tip_start, GO, start_experiment!),
    :start_new => (:start_new_session, :can_start_new, :tip_start_new, GO, start_new_session!),
    :next_run  => (:next_run, :can_prepare_next, :tip_next_run, GO, prepare_next_scenario_run!),
    :continue_changed => (:continue_changed, :can_continue_changed, :tip_continue_changed, WARN,
                          continue_changed_stimulus!),
    :pause     => (:pause, :can_pause, :tip_pause, nothing, pause_experiment!),
    :resume    => (:resume, :can_resume, :tip_resume, GO, resume_experiment!),
    :stop      => (:stop, :can_stop, :tip_stop, DANGER, stop_experiment!),
)

function draw_session_controls!(dashboard::DashboardWindow, available)
    controller = dashboard.controller
    shown = control_buttons(controller)
    isempty(shown) && return nothing
    spacing = unsafe_load(ig.GetStyle().ItemSpacing).x
    width = (ig.GetContentRegionAvail().x - spacing * (length(shown) - 1)) / length(shown)
    ig.Spacing()
    for (index, name) in enumerate(shown)
        index > 1 && ig.SameLine()
        label, available_key, tip, color, action = CONTROL_BUTTONS[name]
        button(ui_label(label), getproperty(available, available_key); width, color) &&
            action(controller)
        tooltip(tip)
    end
    ig.Spacing()
    return nothing
end

# Where the keys go: while a text field is being typed in, it takes them; between
# sessions Enter and Space press a control (`press_control_on_key!`)
function draw_key_guide(dashboard::DashboardWindow)
    control = keyboard_control(dashboard.controller)
    if !dashboard.typing && control !== nothing
        colored_text(ui_label(:keys_between_sessions;
                              action = ui_label(first(CONTROL_BUTTONS[control]))), KEYS_TEXT)
    end
    if dashboard.typing
        colored_text(ui_label(:keys_typing), TYPING_TEXT)
    else
        colored_text(ui_label(:keys_to_responses), KEYS_TEXT)
    end
    tooltip(:tip_keys)
    isempty(dashboard.key_guide) ||
        wrapped_text(join((key * " " * meaning for (key, meaning) in dashboard.key_guide),
                          "   "); color = DIM_TEXT)
    return nothing
end

# ── Data view ────────────────────────────────────────────────────────────────

spread_label(spread::Symbol) = ui_label(Symbol("spread_", spread))
split_label(split::Symbol) = ui_label(Symbol("split_", split))

function plot_line_color(index::Int)
    n = max(Int(ImPlot.GetColormapSize()), 1)
    c = ImPlot.GetColormapColor(mod(index - 1, n))
    return (Float32(c.x), Float32(c.y), Float32(c.z), Float32(c.w))
end

function change_plot_option!(dashboard::DashboardWindow, key::Symbol, value)
    set_dashboard_plot_option!(dashboard.controller, key, value) || return nothing
    dashboard.plot_options = settings_plot_options()
    dashboard.stale = true
    dashboard.settings_stale = true
    return nothing
end

function sync_data_view!(dashboard::DashboardWindow)
    controller = dashboard.controller
    if controller.lists_stale && !is_running(controller)
        reread_lists!(dashboard)
    end
    if dashboard.data_view_key !== nothing &&
       dashboard.data_view_key[1] == controller.ticked &&
       dashboard.data_view_key[2] == controller.checks &&
       dashboard.data_view_key[3] == dashboard.plot_options &&
       dashboard.data_view_key[4] == dashboard.entries_version
        return nothing
    end
    result = load_ticked_data_view(controller.ticked, dashboard.entries,
                                   dashboard.session_cache, dashboard.plot_options;
                                   checks = controller.checks)
    dashboard.data_plot = result.plot
    dashboard.data_rows = result.rows
    dashboard.data_view_key = (copy(controller.ticked), copy(controller.checks),
                               dashboard.plot_options, dashboard.entries_version)
    return nothing
end

function sync_earlier_line!(dashboard::DashboardWindow)
    controller = dashboard.controller
    session = controller.session
    if !dashboard.show_earlier[] || session === nothing
        dashboard.earlier_line = nothing
        dashboard.earlier_key = nothing
        return nothing
    end
    # Never load files from disk while a trial is under way
    session.trial_under_way && return nothing
    if controller.lists_stale && !is_running(controller)
        reread_lists!(dashboard)
    end
    save_path = session.save_path
    if dashboard.earlier_key !== nothing &&
       dashboard.earlier_key[1] == session.id &&
       dashboard.earlier_key[2] == save_path &&
       dashboard.earlier_key[3] == controller.checks &&
       dashboard.earlier_key[4] == dashboard.plot_options &&
       dashboard.earlier_key[5] == dashboard.entries_version
        return nothing
    end
    dashboard.earlier_line = earlier_sessions_line(
        session, dashboard.entries, dashboard.session_cache, dashboard.plot_options;
        checks = controller.checks)
    dashboard.earlier_key = (session.id, save_path, copy(controller.checks),
                             dashboard.plot_options, dashboard.entries_version)
    return nothing
end

function draw_plot_view!(dashboard::DashboardWindow)
    dashboard.show_plot[] || return nothing
    if begin_view(dashboard, :plot)
        controller = dashboard.controller
        live_mode = is_live_plot_mode(controller)
        if live_mode
            sync_earlier_line!(dashboard)
        else
            sync_data_view!(dashboard)
            dashboard.menu_target = nothing
            dashboard.menu_requested = false
        end

        draw_plot_controls!(dashboard, live_mode)

        note = live_mode ? "" : dashboard.data_plot.note
        isempty(note) || wrapped_text(note; color = DIM_TEXT)

        rows = live_mode ? dashboard.live_rows : dashboard.data_rows
        avail_y = ig.GetContentRegionAvail().y
        spacing_y = unsafe_load(ig.GetStyle().ItemSpacing).y
        frame_h = ig.GetFrameHeightWithSpacing()
        table_height = isempty(rows) ? 0f0 :
            min(max(2.4f0 * frame_h, (length(rows) + 1.4f0) * frame_h),
                min(5.5f0 * frame_h, max(2.4f0 * frame_h, 0.30f0 * avail_y)))
        plot_height = isempty(rows) ? -1f0 :
            max(avail_y - table_height - spacing_y, 8f0 * ig.GetFontSize())

        if live_mode
            draw_live_plot!(dashboard, plot_height)
            draw_point_menu!(dashboard)
        else
            draw_data_plot!(dashboard, plot_height)
        end

        isempty(rows) || draw_data_table!(dashboard, rows, table_height)
    end
    ig.End()
    return nothing
end

function draw_plot_controls!(dashboard::DashboardWindow, live_mode::Bool)
    opts = dashboard.plot_options
    style = unsafe_load(ig.GetStyle())
    frame_h = ig.GetFrameHeight()
    gap = style.ItemSpacing.x * 1.2f0

    function next_item(needed::Real)
        ig.SameLine(0f0, gap)
        ig.GetContentRegionAvail().x < needed && ig.NewLine()
    end
    checkbox_width(label::AbstractString) =
        ig.CalcTextSize(label).x + frame_h + style.ItemInnerSpacing.x

    raw_on = Ref(opts.raw)
    ig.Checkbox(ui_label(:show_trial_points), raw_on) &&
        change_plot_option!(dashboard, :raw, raw_on[])
    tooltip(:tip_show_trial_points)

    mean_label = ui_label(:show_means)
    next_item(checkbox_width(mean_label))
    mean_on = Ref(opts.mean)
    ig.Checkbox(mean_label, mean_on) &&
        change_plot_option!(dashboard, :mean, mean_on[])
    tooltip(:tip_show_means)

    spread_text = ui_label(:plot_spread)
    spread_w = max(maximum(s -> ig.CalcTextSize(spread_label(s)).x, PLOT_SPREADS) +
                   frame_h + 2 * style.FramePadding.x, 5.5f0 * ig.GetFontSize())
    next_item(ig.CalcTextSize(spread_text).x + style.ItemInnerSpacing.x + spread_w)
    ig.AlignTextToFramePadding()
    text(spread_text)
    tooltip(:tip_plot_spread)
    ig.SameLine(0f0, style.ItemInnerSpacing.x)
    ig.SetNextItemWidth(spread_w)
    if ig.BeginCombo("##plot_spread", spread_label(opts.spread))
        for spread in PLOT_SPREADS
            ig.Selectable(spread_label(spread), spread === opts.spread) &&
                spread !== opts.spread && change_plot_option!(dashboard, :spread, spread)
        end
        ig.EndCombo()
    end
    tooltip(:tip_plot_spread)

    smooth_label = ui_label(:plot_smooth)
    next_item(checkbox_width(smooth_label))
    smooth_on = Ref(opts.smooth)
    ig.Checkbox(smooth_label, smooth_on) &&
        change_plot_option!(dashboard, :smooth, smooth_on[])
    tooltip(:tip_plot_smooth)

    fit_label = ui_label(:plot_fit_toggle)
    next_item(checkbox_width(fit_label))
    fit_on = Ref(opts.fit)
    ig.Checkbox(fit_label, fit_on) &&
        change_plot_option!(dashboard, :fit, fit_on[])
    tooltip(:tip_plot_fit)

    conv_label = ui_label(:plot_converted)
    next_item(checkbox_width(conv_label))
    conv_on = Ref(opts.converted)
    ig.Checkbox(conv_label, conv_on) &&
        change_plot_option!(dashboard, :converted, conv_on[])
    tooltip(:tip_plot_converted)

    if !live_mode
        split_text = ui_label(:plot_split)
        split_w = max(maximum(s -> ig.CalcTextSize(split_label(s)).x, PLOT_SPLITS) +
                      frame_h + 2 * style.FramePadding.x, 7.0f0 * ig.GetFontSize())
        next_item(ig.CalcTextSize(split_text).x + style.ItemInnerSpacing.x + split_w)
        ig.AlignTextToFramePadding()
        text(split_text)
        tooltip(:tip_plot_split)
        ig.SameLine(0f0, style.ItemInnerSpacing.x)
        ig.SetNextItemWidth(split_w)
        if ig.BeginCombo("##plot_split", split_label(opts.split))
            for split in PLOT_SPLITS
                ig.Selectable(split_label(split), split === opts.split) &&
                    split !== opts.split && change_plot_option!(dashboard, :split, split)
            end
            ig.EndCombo()
        end
        tooltip(:tip_plot_split)
    elseif dashboard.controller.session !== nothing
        earlier_label = ui_label(:plot_earlier_sessions)
        next_item(checkbox_width(earlier_label))
        ig.Checkbox(earlier_label, dashboard.show_earlier)
        tooltip(:tip_plot_earlier_sessions)
    end
    return nothing
end

function draw_smooth_line!(label::AbstractString, points::Vector{AggregatePoint},
                           smooth_y::Vector{Float64}, color::RGBA, scale::Float32)
    (isempty(points) || isempty(smooth_y)) && return nothing
    spec = ImPlot.ImPlotSpec(LineColor = color, LineWeight = 1.5f0 * scale)
    first_group = true
    for others in unique(point.vals[2:end] for point in points)
        members = sort!(findall(point -> point.vals[2:end] == others, points);
                        by = index -> points[index].level)
        xs = Float64[points[index].level for index in members]
        ys = Float64[smooth_y[index] for index in members]
        ImPlot.PlotLine(first_group ? label : "##smooth_seg", xs, ys; spec)
        first_group = false
    end
    return nothing
end

function draw_earlier_line!(dashboard::DashboardWindow, line::DashboardPlotLine)
    opts = dashboard.plot_options
    color = EARLIER_LINE
    label = line.label * "##earlier"
    legend_used = false
    if opts.mean && !isempty(line.x)
        if !isempty(line.err_lo)
            ImPlot.PlotErrorBars(label, line.x, line.y, line.err_lo, line.err_hi;
                                 spec = ImPlot.ImPlotSpec(LineColor = color,
                                                          LineWeight = 1.2f0 * dashboard.scale))
        end
        ImPlot.PlotScatter(label, line.x, line.y;
                           spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                    MarkerSize = 4f0 * dashboard.scale,
                                                    FillAlpha = 0.45f0,
                                                    MarkerFillColor = color,
                                                    MarkerLineColor = color))
        legend_used = true
    end
    if !isempty(line.smooth_y)
        draw_smooth_line!(legend_used ? "##earlier_smooth" : label,
                          line.points, line.smooth_y, tint(color, 0.85f0), dashboard.scale)
        legend_used = true
    end
    if !isempty(line.curve_x)
        ImPlot.PlotLine(legend_used ? "##earlier_fit" : label,
                        line.curve_x, line.curve_y;
                        spec = ImPlot.ImPlotSpec(LineColor = color,
                                                 LineWeight = 1.5f0 * dashboard.scale))
    end
    return nothing
end

function draw_live_plot!(dashboard::DashboardWindow, height::Real)
    series = dashboard.series
    opts = dashboard.plot_options
    earlier = dashboard.earlier_line
    # A status display, not an exploration tool: no menus, no box zoom, and the
    # axes follow the data. The legend stands below the axis, so every point drawn
    # can be pointed at.
    flags = ImPlot.ImPlotFlags_NoMenus | ImPlot.ImPlotFlags_NoBoxSelect
    # An axis that follows the data leaves room for the markers at its ends; the plot
    # reads the padding when it fits, which is after its first item
    ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FitPadding, ig.ImVec2(0.05f0, 0.08f0))
    if !ImPlot.BeginPlot(series.spec.title * "###live", ig.ImVec2(-1f0, Float32(height)), flags)
        ImPlot.PopStyleVar()
        return nothing
    end

    x_limits = series.x_limits
    y_limits = series.y_limits
    if earlier !== nothing && !isempty(earlier.x)
        if x_limits !== nothing
            x_limits = (min(x_limits[1], minimum(earlier.x)),
                        max(x_limits[2], maximum(earlier.x)))
        end
        if y_limits == PROPORTION_LIMITS && !all(v -> 0 <= v <= 1, earlier.y)
            y_limits = nothing
        end
    end

    ImPlot.SetupAxes(series.spec.x_label, series.spec.y_label,
                     x_limits === nothing ? ImPlot.ImPlotAxisFlags_AutoFit : 0,
                     y_limits === nothing ? ImPlot.ImPlotAxisFlags_AutoFit : 0)
    x_limits === nothing ||
        ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, x_limits..., ImPlot.ImPlotCond_Always)
    y_limits === nothing ||
        ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, y_limits..., ImPlot.ImPlotCond_Always)
    isempty(series.x_ticks) ||
        ImPlot.SetupAxisTicks(ImPlot.ImAxis_X1, series.x_ticks, length(series.x_ticks))
    ImPlot.SetupLegend(ImPlot.ImPlotLocation_South,
                       ImPlot.ImPlotLegendFlags_NoButtons | ImPlot.ImPlotLegendFlags_Outside |
                       ImPlot.ImPlotLegendFlags_Horizontal)

    earlier === nothing || draw_earlier_line!(dashboard, earlier)
    trials = opts.raw ? series.trials : DashboardTrialPoint[]
    draw_trial_points(dashboard, trials)
    if opts.mean && !isempty(series.x)
        data = ui_label(:show_means)
        isempty(series.err_lo) ||
            ImPlot.PlotErrorBars(data, series.x, series.y, series.err_lo, series.err_hi;
                                 spec = ImPlot.ImPlotSpec(LineColor = MEANS,
                                                          LineWeight = 1.5f0 * dashboard.scale))
        ImPlot.PlotScatter(data, series.x, series.y;
                           spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                    MarkerSize = 5f0 * dashboard.scale,
                                                    MarkerFillColor = MEANS,
                                                    MarkerLineColor = MEANS))
    end
    isempty(series.smooth_y) ||
        draw_smooth_line!(ui_label(:plot_smooth_legend), series.points, series.smooth_y,
                          SMOOTH_LINE, dashboard.scale)
    isempty(series.curve_x) ||
        ImPlot.PlotLine(ui_label(:plot_fit), series.curve_x, series.curve_y;
                        spec = ImPlot.ImPlotSpec(LineColor = ACCENT,
                                                 LineWeight = 2f0 * dashboard.scale))

    if ImPlot.IsPlotHovered()
        target = target_under_mouse(dashboard, trials)
        target === nothing || target_tooltip(series, target)
        # Away from every point, the plot offers the design's conditions: a stimulus
        # still to come is chosen there
        if ig.IsMouseClicked(ig.lib.ImGuiMouseButton_Right)
            dashboard.menu_target = something(target, :design)
            dashboard.menu_requested = true
        end
    end
    ImPlot.EndPlot()
    ImPlot.PopStyleVar()
    return nothing
end

function draw_data_plot!(dashboard::DashboardWindow, height::Real)
    plot = dashboard.data_plot
    if isempty(plot.panels)
        if ig.BeginChild("data_empty", (0f0, Float32(height)))
            wrapped_text(ui_label(:data_no_ticked_loaded); color = DIM_TEXT)
        end
        ig.EndChild()
        return nothing
    end

    n = length(plot.panels)
    if n == 1
        draw_plot_panel!(dashboard, 1, plot.panels[1], plot.panel_specs[1],
                         plot.panel_x_limits[1], plot.panel_y_limits[1],
                         plot.panel_x_ticks[1], ig.ImVec2(-1f0, Float32(height)), 0)
        return nothing
    end

    cols = ceil(Int, sqrt(n))
    rows = cld(n, cols)
    subplot_flags = ImPlot.ImPlotSubplotFlags_NoTitle |
                    ImPlot.ImPlotSubplotFlags_NoMenus |
                    ImPlot.ImPlotSubplotFlags_NoResize
    if ImPlot.BeginSubplots("##data_panels", rows, cols,
                            ig.ImVec2(-1f0, Float32(height)), subplot_flags)
        for idx in 1:n
            draw_plot_panel!(dashboard, idx, plot.panels[idx], plot.panel_specs[idx],
                             plot.panel_x_limits[idx], plot.panel_y_limits[idx],
                             plot.panel_x_ticks[idx], ig.ImVec2(-1f0, -1f0), idx - 1)
        end
        ImPlot.EndSubplots()
    end
    return nothing
end

function draw_plot_panel!(dashboard::DashboardWindow, panel_idx::Int,
                          lines::Vector{DashboardPlotLine}, spec::DashboardPlotSpec,
                          x_limits::Union{Nothing, Tuple{Float64, Float64}},
                          y_limits::Union{Nothing, Tuple{Float64, Float64}},
                          x_ticks::Vector{Float64}, size, color_offset::Int)
    flags = ImPlot.ImPlotFlags_NoMenus | ImPlot.ImPlotFlags_NoBoxSelect
    ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FitPadding, ig.ImVec2(0.05f0, 0.08f0))
    if !ImPlot.BeginPlot(spec.title * "###data_panel_$panel_idx", size, flags)
        ImPlot.PopStyleVar()
        return nothing
    end
    ImPlot.SetupAxes(spec.x_label, spec.y_label,
                     x_limits === nothing ? ImPlot.ImPlotAxisFlags_AutoFit : 0,
                     y_limits === nothing ? ImPlot.ImPlotAxisFlags_AutoFit : 0)
    x_limits === nothing ||
        ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, x_limits..., ImPlot.ImPlotCond_Always)
    y_limits === nothing ||
        ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, y_limits..., ImPlot.ImPlotCond_Always)
    isempty(x_ticks) ||
        ImPlot.SetupAxisTicks(ImPlot.ImAxis_X1, x_ticks, length(x_ticks))
    ImPlot.SetupLegend(ImPlot.ImPlotLocation_South,
                       ImPlot.ImPlotLegendFlags_NoButtons | ImPlot.ImPlotLegendFlags_Outside |
                       ImPlot.ImPlotLegendFlags_Horizontal)

    for (i, line) in enumerate(lines)
        color = plot_line_color(color_offset + i)
        draw_plot_line!(dashboard, line, color, color_offset + i)
    end

    if dashboard.plot_options.mean && ImPlot.IsPlotHovered()
        data_panel_tooltip(dashboard, lines, spec)
    end
    ImPlot.EndPlot()
    ImPlot.PopStyleVar()
    return nothing
end

function draw_plot_line!(dashboard::DashboardWindow, line::DashboardPlotLine,
                         color::RGBA, index::Int)
    opts = dashboard.plot_options
    legend_label = line.label * "##line_$index"
    has_summary = (opts.mean && !isempty(line.x)) || !isempty(line.curve_x) ||
                  !isempty(line.smooth_y)

    if !isempty(line.trials)
        size = 3f0 * dashboard.scale
        counted = filter(t -> t.counted, line.trials)
        isempty(counted) ||
            ImPlot.PlotScatter(has_summary ? "##trials_$index" : legend_label,
                               [t.x for t in counted], [t.y for t in counted];
                               spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                        MarkerSize = size, FillAlpha = 0.40f0,
                                                        MarkerFillColor = tint(color, 0.55f0),
                                                        MarkerLineColor = tint(color, 0.55f0)))
        set_aside = filter(t -> !t.counted, line.trials)
        isempty(set_aside) ||
            ImPlot.PlotScatter("##not_counted_$index",
                               [t.x for t in set_aside], [t.y for t in set_aside];
                               spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                        MarkerSize = size, FillAlpha = 0f0,
                                                        MarkerLineColor = SET_ASIDE_POINTS))
    end

    if opts.mean && !isempty(line.x)
        isempty(line.err_lo) ||
            ImPlot.PlotErrorBars(legend_label, line.x, line.y, line.err_lo, line.err_hi;
                                 spec = ImPlot.ImPlotSpec(LineColor = color,
                                                          LineWeight = 1.5f0 * dashboard.scale))
        ImPlot.PlotScatter(legend_label, line.x, line.y;
                           spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                    MarkerSize = 5f0 * dashboard.scale,
                                                    MarkerFillColor = color,
                                                    MarkerLineColor = color))
    end

    if !isempty(line.smooth_y)
        smooth_lbl = (!opts.mean && isempty(line.curve_x)) ? legend_label : "##smooth_$index"
        draw_smooth_line!(smooth_lbl, line.points, line.smooth_y,
                          tint(color, 0.85f0), dashboard.scale)
    end

    if !isempty(line.curve_x)
        ImPlot.PlotLine(legend_label, line.curve_x, line.curve_y;
                        spec = ImPlot.ImPlotSpec(LineColor = color,
                                                 LineWeight = 2f0 * dashboard.scale))
    end
    return nothing
end

function data_panel_tooltip(dashboard::DashboardWindow, lines::Vector{DashboardPlotLine},
                            spec::DashboardPlotSpec)
    mouse = ig.GetMousePos()
    reach = 12 * dashboard.scale
    best_dist = reach + 1
    best_line = nothing
    best_idx = 0
    for line in lines
        for idx in eachindex(line.x)
            pixel = ImPlot.PlotToPixels(line.x[idx], line.y[idx])
            d = hypot(pixel.x - mouse.x, pixel.y - mouse.y)
            if d < best_dist
                best_dist = d
                best_line = line
                best_idx = idx
            end
        end
    end
    best_line === nothing && return nothing
    ig.BeginTooltip()
    isempty(best_line.label) || colored_text(best_line.label, DIM_TEXT)
    text(ui_label(:point_header; level = format_level(best_line.x[best_idx]),
                  count = best_line.n[best_idx]))
    text(spec.y_label * ": " * format_level(best_line.y[best_idx]))
    ig.EndTooltip()
    return nothing
end

function draw_data_table!(dashboard::DashboardWindow, rows::Vector{DataViewRow}, height::Real)
    has_tick = any(r -> r.tickable, rows)
    columns = ((:column_date, 1.1f0), (:column_trials, 0.65f0),
               (:column_state, 0.8f0), (:column_comment, 2.0f0))
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    ncols = length(columns) + (has_tick ? 1 : 0)
    ig.BeginTable("data_sessions", ncols, flags, (0f0, Float32(height))) || return nothing
    ig.TableSetupScrollFreeze(0, 1)
    has_tick &&
        ig.TableSetupColumn("##tick", ig.lib.ImGuiTableColumnFlags_WidthFixed, ig.GetFrameHeight())
    for (column, weight) in columns
        ig.TableSetupColumn(ui_label(column), ig.lib.ImGuiTableColumnFlags_WidthStretch, weight)
    end
    ig.TableHeadersRow()

    for (idx, row) in enumerate(rows)
        ig.PushID(isempty(row.path) ? idx : row.path)
        ig.TableNextRow()
        if has_tick
            ig.TableNextColumn()
            if row.tickable
                ticked = Ref(row.path in dashboard.controller.ticked)
                ig.Checkbox("##tick", ticked) &&
                    tick_session!(dashboard.controller, row.path, ticked[])
                tooltip(:tip_untick_session)
            end
        end
        ig.TableNextColumn(); text(isempty(row.date) ? "—" : row.date)
        ig.TableNextColumn(); text(isempty(row.trials) ? "—" : row.trials)
        ig.TableNextColumn(); text(row.state)
        ig.TableNextColumn()
        text(row.comment)
        isempty(row.comment) || tooltip(row.comment)
        ig.PopID()
    end
    ig.EndTable()
    return nothing
end

# Small and translucent, under the conditions' points; a trial that no longer counts
# is drawn as a ring, with no entry in the legend
function draw_trial_points(dashboard::DashboardWindow, trials::Vector{DashboardTrialPoint})
    isempty(trials) && return nothing
    size = 3f0 * dashboard.scale
    counted = filter(t -> t.counted, trials)
    isempty(counted) ||
        ImPlot.PlotScatter(ui_label(:show_trial_points), [t.x for t in counted],
                           [t.y for t in counted];
                           spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                    MarkerSize = size, FillAlpha = 0.5f0,
                                                    MarkerFillColor = TRIAL_POINTS,
                                                    MarkerLineColor = TRIAL_POINTS))
    set_aside = filter(t -> !t.counted, trials)
    isempty(set_aside) ||
        ImPlot.PlotScatter("##not_counted", [t.x for t in set_aside], [t.y for t in set_aside];
                           spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle,
                                                    MarkerSize = size, FillAlpha = 0f0,
                                                    MarkerLineColor = SET_ASIDE_POINTS))
    return nothing
end

# The point nearest the mouse within reach: a condition's point, or one trial. A
# condition's point is drawn over the trials, so it wins where the two coincide.
function target_under_mouse(dashboard::DashboardWindow, trials::Vector{DashboardTrialPoint})
    series = dashboard.series
    mouse = ig.GetMousePos()
    distance(x, y) = (pixel = ImPlot.PlotToPixels(x, y); hypot(pixel.x - mouse.x, pixel.y - mouse.y))
    reach = 12 * dashboard.scale
    point, point_distance = dashboard.plot_options.mean ?
                            nearest(series.points, distance.(series.x, series.y)) :
                            (nothing, Inf)
    trial, trial_distance = nearest(trials, [distance(t.x, t.y) for t in trials])
    point !== nothing && point_distance <= min(trial_distance, reach) && return point
    return trial_distance <= reach ? trial : nothing
end

nearest(items, distances) =
    isempty(items) ? (nothing, Inf) : (i = argmin(distances); (items[i], distances[i]))

function target_tooltip(series::DashboardPlotSeries, point::AggregatePoint)
    ig.BeginTooltip()
    text(ui_label(:point_header; level = format_level(point.level), count = point.n))
    value = series.y[findfirst(p -> p === point, series.points)]
    text(series.spec.y_label * ": " * format_level(value))
    ig.EndTooltip()
    return nothing
end

function target_tooltip(series::DashboardPlotSeries, trial::DashboardTrialPoint)
    ig.BeginTooltip()
    text(ui_label(:trial_entry; trial = trial.trial, answer = trial.answer))
    text(series.spec.x_label * ": " * format_level(trial.level))
    trial.counted || colored_text(ui_label(:trial_not_counted), DIM_TEXT)
    ig.EndTooltip()
    return nothing
end

# A right-clicked condition is presented again or lists the trials behind it, each
# with the corrections it allows; a right-clicked trial offers its corrections at
# once; the plot itself offers every condition of the design
function draw_point_menu!(dashboard::DashboardWindow)
    # Opened once, so a menu closed by a click elsewhere or by Escape stays closed
    dashboard.menu_requested && ig.OpenPopup("point_menu")
    dashboard.menu_requested = false
    if ig.BeginPopup("point_menu")
        session = dashboard.controller.session
        target = dashboard.menu_target
        session === nothing || target === nothing || draw_target_menu!(dashboard, session, target)
        ig.EndPopup()
    else
        dashboard.menu_target = nothing
    end
    return nothing
end

function draw_target_menu!(dashboard::DashboardWindow, session::SessionContext,
                           point::AggregatePoint)
    converted = dashboard.plot_options.converted
    trials = dashboard_point_trials(session, point; converted)
    colored_text(ui_label(:point_header; level = format_level(point.level),
                          count = length(trials)), DIM_TEXT)
    ig.Separator()
    isempty(trials) || draw_condition_actions!(dashboard,
                                               dashboard_point_condition(session, point; converted))
    ig.Separator()
    for trial in trials
        entry = ui_label(:trial_entry; trial = trial.trial_index,
                         answer = trial_response_text(trial))
        trial.is_valid || (entry *= " · " * ui_label(:trial_not_counted))
        if ig.BeginMenu(entry * "##" * string(trial.trial_index))
            draw_trial_actions!(dashboard, trial.trial_index)
            ig.EndMenu()
        end
    end
    return nothing
end

function draw_target_menu!(dashboard::DashboardWindow, ::SessionContext,
                           trial::DashboardTrialPoint)
    entry = ui_label(:trial_entry; trial = trial.trial, answer = trial.answer)
    trial.counted || (entry *= " · " * ui_label(:trial_not_counted))
    colored_text(entry, DIM_TEXT)
    ig.Separator()
    draw_trial_actions!(dashboard, trial.trial)
    return nothing
end

function draw_target_menu!(dashboard::DashboardWindow, session::SessionContext, ::Symbol)
    colored_text(ui_label(:present_condition), DIM_TEXT)
    ig.Separator()
    for (label, vals) in dashboard_design_conditions(session)
        if ig.BeginMenu(label * "##" * label)
            draw_condition_actions!(dashboard, vals)
            ig.EndMenu()
        end
    end
    return nothing
end

# A condition presented as an answer added to the others, next or at once
function draw_condition_actions!(dashboard::DashboardWindow, vals::Vector{Float64})
    controller = dashboard.controller
    presentable = can_present(controller)
    now = presentable && controller.session.trial_run !== nothing
    menu_item(:condition_next, presentable) && present_dashboard_condition!(controller, vals)
    menu_item(:condition_now, now) &&
        present_dashboard_condition!(controller, vals; when = :now)
    return nothing
end

function draw_trial_actions!(dashboard::DashboardWindow, trial::Int)
    controller = dashboard.controller
    actions = trial_actions(controller, trial)
    menu_item(:mark_outlier, actions.can_mark_outlier) &&
        mark_dashboard_outlier!(controller, trial)
    ig.Separator()
    menu_item(:replace_next, actions.can_repeat) && repeat_dashboard_trial!(controller, trial)
    menu_item(:replace_now, actions.can_repeat && actions.can_now) &&
        repeat_dashboard_trial!(controller, trial; when = :now)
    menu_item(:add_next, actions.can_add) && add_dashboard_trial!(controller, trial)
    menu_item(:add_now, actions.can_add && actions.can_now) &&
        add_dashboard_trial!(controller, trial; when = :now)
    return nothing
end

# ── Trials ───────────────────────────────────────────────────────────────────

function draw_trials_view!(dashboard::DashboardWindow)
    dashboard.show_trials[] || return nothing
    if begin_view(dashboard, :trials)
        ig.Checkbox(ui_label(:show_not_counted), dashboard.show_not_counted)
        tooltip(:tip_show_not_counted)
        draw_trial_table!(dashboard)
    end
    ig.End()
    return nothing
end

function draw_trial_table!(dashboard::DashboardWindow)
    headers = dashboard.headers
    isempty(headers) && return nothing
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV |
            ig.lib.ImGuiTableFlags_ScrollY | ig.lib.ImGuiTableFlags_Resizable
    ig.BeginTable("trials", length(headers), flags) || return nothing
    ig.TableSetupScrollFreeze(0, 1)
    foreach(header -> ig.TableSetupColumn(header), headers)
    ig.TableHeadersRow()
    for row in dashboard.rows
        (row.counted || dashboard.show_not_counted[]) || continue
        draw_trial_row!(dashboard, row)
    end
    dashboard.scroll_to_end && (ig.SetScrollHereY(1.0f0); dashboard.scroll_to_end = false)
    ig.EndTable()
    return nothing
end

# A row is one selectable spanning the table, so a right-click anywhere on it
# opens the trial's corrections
function draw_trial_row!(dashboard::DashboardWindow, row::DashboardTrialRow)
    ig.PushID(row.trial)
    ig.TableNextRow()
    ig.TableNextColumn()
    row.counted || ig.PushStyleColor(ig.lib.ImGuiCol_Text, DIM_TEXT)
    ig.Selectable(string(row.trial), false,
                  ig.lib.ImGuiSelectableFlags_SpanAllColumns |
                  ig.lib.ImGuiSelectableFlags_AllowOverlap)
    row.counted || ig.PopStyleColor()
    if ig.BeginPopupContextItem("trial_menu")
        draw_trial_actions!(dashboard, row.trial)
        ig.EndPopup()
    end
    cells = [row.values; row.response; row.answered_at;
             row.counted ? "" : ui_label(:trial_not_counted)]
    for cell in cells
        ig.TableNextColumn()
        row.counted ? text(cell) : colored_text(cell, DIM_TEXT)
    end
    ig.PopID()
    return nothing
end

# ── Settings ─────────────────────────────────────────────────────────────────

# The settings of this rig and project, each value edited in place beside the file it
# comes from. The files are read when the view opens, after a
# change and on Refresh, not every frame.
function draw_settings_view!(dashboard::DashboardWindow)
    if !dashboard.show_settings[]
        dashboard.settings_open = false
        return nothing
    end
    if !dashboard.settings_open
        dashboard.settings_open = dashboard.settings_stale = true
        dashboard.settings_outcome = nothing
        ig.SetNextWindowFocus()
    end
    if begin_view(dashboard, :settings)
        dashboard.settings_stale && reread_settings!(dashboard)
        wrapped_text(ui_label(:settings_intro); color = DIM_TEXT)
        dashboard.settings_unread === nothing ||
            wrapped_text(dashboard.settings_unread; color = SET_ASIDE_POINTS)
        outcome = dashboard.settings_outcome
        outcome === nothing ||
            wrapped_text(outcome[2]; color = outcome[1] ? KEYS_TEXT : SET_ASIDE_POINTS)
        for section in dashboard.settings
            section_bar("[$(section.name)]") || continue
            ig.PushID(section.name)
            draw_settings_source!(dashboard, section)
            draw_settings_table!(dashboard, section)
            ig.PopID()
        end
    end
    ig.End()
    return nothing
end

function reread_settings!(dashboard::DashboardWindow)
    dashboard.settings_stale = false
    dashboard.settings = dashboard_settings()
    dashboard.settings_targets = settings_targets()
    dashboard.settings_unread = unread_settings_text()
    return nothing
end

# The file a value no file sets yet will be written to, chosen from those that would be
# read
function draw_settings_source!(dashboard::DashboardWindow, section::SettingsSectionRows)
    all(row -> row.in_file, section.rows) && return nothing
    colored_text(ui_label(:settings_new_keys_to), DIM_TEXT)
    targets = dashboard.settings_targets
    chosen = settings_target(dashboard, section)
    shown(path) = isfile(path) ? path : ui_label(:settings_new_file; path)
    ig.SetNextItemWidth(-1f0)
    if ig.BeginCombo("##target", shown(chosen))
        for path in targets
            ig.Selectable(shown(path), path == chosen) &&
                (dashboard.settings_target[section.name] = path)
        end
        ig.EndCombo()
    end
    tooltip(:tip_settings_target)
    return nothing
end

function settings_target(dashboard::DashboardWindow, section::SettingsSectionRows)
    chosen = get(dashboard.settings_target, section.name, nothing)
    return chosen in dashboard.settings_targets ? chosen : section.target
end

# Where a value comes from, by a short name: the rig's own file, or the folder of a
# project's; the whole path in the tooltip
function settings_file_name(path::AbstractString)
    path == user_settings_file() && return ui_label(:settings_rig_file)
    return basename(dirname(path))
end

# Each key, its value in effect as an edit field, its default, the file that sets it,
# and Reset for a key a file sets
function draw_settings_table!(dashboard::DashboardWindow, section::SettingsSectionRows)
    flags = ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_BordersInnerV
    ig.BeginTable("settings", 5, flags) || return nothing
    reset_width = ig.CalcTextSize(ui_label(:reset_setting)).x +
                  2 * unsafe_load(ig.GetStyle().FramePadding).x
    ig.TableSetupColumn(ui_label(:column_setting), ig.lib.ImGuiTableColumnFlags_WidthStretch, 1.1f0)
    ig.TableSetupColumn(ui_label(:column_value), ig.lib.ImGuiTableColumnFlags_WidthStretch, 2.0f0)
    ig.TableSetupColumn(ui_label(:column_default), ig.lib.ImGuiTableColumnFlags_WidthStretch, 1.1f0)
    ig.TableSetupColumn(ui_label(:column_file), ig.lib.ImGuiTableColumnFlags_WidthStretch, 0.9f0)
    ig.TableSetupColumn("##reset", ig.lib.ImGuiTableColumnFlags_WidthFixed, reset_width)
    ig.TableHeadersRow()
    for row in section.rows
        ig.PushID(row.key)
        ig.TableNextRow()
        ig.TableNextColumn()
        ig.AlignTextToFramePadding()
        text(row.key)
        tooltip(row.tip)
        ig.TableNextColumn()
        draw_setting_field!(dashboard, section, row)
        ig.TableNextColumn()
        ig.AlignTextToFramePadding()
        colored_text(row.default, DIM_TEXT)
        tooltip(row.default)
        ig.TableNextColumn()
        if row.source !== nothing
            ig.AlignTextToFramePadding()
            replaced = row.replaces === nothing ? "" :
                       "\n" * ui_label(:settings_replaces_rig; value = row.replaces)
            row.replaces === nothing ? colored_text(settings_file_name(row.source), DIM_TEXT) :
                                       text(settings_file_name(row.source) * " *")
            tooltip(ui_label(:settings_from_file; path = row.source) * replaced)
        end
        ig.TableNextColumn()
        if row.in_file && !row.required
            if button(ui_label(:reset_setting), true)
                setting_written!(dashboard, section, row,
                                 reset_dashboard_setting!(dashboard.controller, section.name,
                                                          row.key))
            end
            tooltip(:tip_reset_setting)
        end
        ig.PopID()
    end
    ig.EndTable()
    return nothing
end

# A setting's edit field: a switch, a list, or text written when Enter is pressed. A
# refused value stays in its field to be corrected, the field marked.
function draw_setting_field!(dashboard::DashboardWindow, section::SettingsSectionRows,
                             row::SettingRow)
    # A value a file sets is changed in that file
    target = row.in_file ? nothing : settings_target(dashboard, section)
    write_value(text) = setting_written!(dashboard, section, row,
                                         edit_dashboard_setting!(dashboard.controller,
                                                                 section.name, row.key, text;
                                                                 target))
    if row.kind === :bool
        on = Ref(row.value == "true")
        ig.Checkbox("##value", on) && write_value(string(on[]))
        return nothing
    elseif !isempty(row.choices)
        ig.SetNextItemWidth(-1f0)
        if ig.BeginCombo("##value", row.value)
            for choice in row.choices
                ig.Selectable(choice, choice == row.value) && choice != row.value &&
                    write_value(choice)
            end
            ig.EndCombo()
        end
        return nothing
    end
    id = section.name * "." * row.key
    buffer = get!(() -> text_buffer(row.value), dashboard.setting_buffers, id)
    refused = id in dashboard.refused_settings
    dashboard.editing_setting != id && !refused && buffer_text(buffer) != row.value &&
        fill_buffer!(buffer, row.value)
    refused && ig.PushStyleColor(ig.lib.ImGuiCol_FrameBg, REFUSED)
    ig.SetNextItemWidth(-1f0)
    ig.InputText("##value", buffer, length(buffer))
    refused && ig.PopStyleColor()
    if ig.IsItemActive()
        dashboard.editing_setting = id
    elseif dashboard.editing_setting == id
        dashboard.editing_setting = nothing
    end
    submitted(refused) && write_value(buffer_text(buffer))
    tooltip(:tip_edit_setting)
    return nothing
end

# After a change was written or refused: the outcome shown at the top of the view, the
# field marked if refused, and what the files feed read again
function setting_written!(dashboard::DashboardWindow, section::SettingsSectionRows,
                          row::SettingRow, written::Bool)
    id = section.name * "." * row.key
    dashboard.settings_outcome = (written, dashboard.controller.message)
    if written
        delete!(dashboard.refused_settings, id)
        dashboard.settings_stale = true
        # Browse lists the directories the storage settings name
        section.name == "storage" && (dashboard.controller.lists_stale = true)
        section.name == "plot" && (dashboard.plot_options_stale = true)
    else
        row.kind === :bool || !isempty(row.choices) || push!(dashboard.refused_settings, id)
    end
    return nothing
end

# ── Messages ─────────────────────────────────────────────────────────────────

# What the dashboard told the operator, oldest first: the control panel shows only
# the last message, and an outcome is easily missed while watching the participant
function draw_messages_view!(dashboard::DashboardWindow)
    dashboard.show_messages[] || return nothing
    if begin_view(dashboard, :messages)
        messages = dashboard.controller.messages
        width = 5.5f0 * ig.GetFontSize()
        for (at, message) in messages
            colored_text(Libc.strftime("%H:%M:%S", at), DIM_TEXT)
            ig.SameLine(width)
            wrapped_text(message)
        end
        # Follow new messages, unless the operator has scrolled up to read old ones
        if length(messages) != dashboard.messages_shown
            ig.GetScrollY() >= ig.GetScrollMaxY() - 1 && ig.SetScrollHereY(1.0f0)
            dashboard.messages_shown = length(messages)
        end
    end
    ig.End()
    return nothing
end
