local obslua = obslua

local source_windows_csv = ""
local source_browser_name = ""
local pad_t, pad_b, pad_l, pad_r = 0, 0, 0, 0

function update_wrap()
    local current_scene_source = obslua.obs_frontend_get_current_scene()
    if not current_scene_source then return end
    
    local scene = obslua.obs_scene_from_source(current_scene_source)
    local found_items = {}
    local found_visibility = {}

    -- RECURSIVE INVENTORY: Handles Groups and Nested Scenes
    local function inventory_scene(scene_ptr, parent_visible)
        local items = obslua.obs_scene_enum_items(scene_ptr)
        if items ~= nil then
            for _, item in ipairs(items) do
                local source = obslua.obs_sceneitem_get_source(item)
                local name = obslua.obs_source_get_name(source)
                local is_vis = obslua.obs_sceneitem_visible(item) and parent_visible
                
                found_items[name] = item
                found_visibility[name] = is_vis

                if obslua.obs_sceneitem_is_group(item) then
                    local g_scene = obslua.obs_group_from_source(source)
                    if g_scene ~= nil then inventory_scene(g_scene, is_vis) end
                else
                    local n_scene = obslua.obs_scene_from_source(source)
                    if n_scene ~= nil then inventory_scene(n_scene, is_vis) end
                end
            end
            obslua.sceneitem_list_release(items)
        end
    end

    inventory_scene(scene, true)

    local target_names = {}
    for s in string.gmatch(source_windows_csv, "([^,]+)") do
        table.insert(target_names, s:match("^%s*(.-)%s*$"))
    end

    local active_window_item = nil
    local active_window_name = nil

    for _, t_name in ipairs(target_names) do
        if found_items[t_name] and found_visibility[t_name] then
            active_window_name = t_name
            active_window_item = found_items[t_name]
            break
        end
    end

    local browser_item = found_items[source_browser_name]

    if browser_item and active_window_item then
        obslua.obs_sceneitem_set_visible(browser_item, true)
        
        local source_window = obslua.obs_sceneitem_get_source(active_window_item)
        local source_browser = obslua.obs_sceneitem_get_source(browser_item)
        
        -- 1. TRANSFORM ENGINE (Restored Alignment & Bounds Logic)
        local raw_w = obslua.obs_source_get_width(source_window)
        local raw_h = obslua.obs_source_get_height(source_window)
        local crop = obslua.obs_sceneitem_crop()
        obslua.obs_sceneitem_get_crop(active_window_item, crop)

        local base_w = raw_w - crop.left - crop.right
        local base_h = raw_h - crop.top - crop.bottom

        if base_w > 0 and base_h > 0 then
            local t_win = obslua.obs_transform_info()
            obslua.obs_sceneitem_get_info2(active_window_item, t_win)

            local vis_w = base_w * math.abs(t_win.scale.x)
            local vis_h = base_h * math.abs(t_win.scale.y)
            local box_w, box_h = vis_w, vis_h

            if t_win.bounds_type ~= obslua.OBS_BOUNDS_NONE then
                box_w, box_h = t_win.bounds.x, t_win.bounds.y
                local sx, sy = box_w / base_w, box_h / base_h
                if t_win.bounds_type == obslua.OBS_BOUNDS_STRETCH then vis_w, vis_h = box_w, box_h
                elseif t_win.bounds_type == obslua.OBS_BOUNDS_SCALE_INNER or t_win.bounds_type == obslua.OBS_BOUNDS_MAX_ONLY then
                    local s = math.min(sx, sy); vis_w, vis_h = base_w * s, base_h * s
                elseif t_win.bounds_type == obslua.OBS_BOUNDS_SCALE_OUTER then
                    local s = math.max(sx, sy); vis_w, vis_h = base_w * s, base_h * s
                elseif t_win.bounds_type == obslua.OBS_BOUNDS_SCALE_TO_WIDTH then vis_w, vis_h = box_w, base_h * sx
                elseif t_win.bounds_type == obslua.OBS_BOUNDS_SCALE_TO_HEIGHT then vis_w, vis_h = base_w * sy, box_h
                end
            end

            -- Calculate Alignment Offset
            local bx, by = t_win.pos.x, t_win.pos.y
            if t_win.alignment % 2 == 0 then bx = bx - (box_w / 2) elseif math.floor(t_win.alignment / 2) % 2 == 1 then bx = bx - box_w end
            if math.floor(t_win.alignment / 4) % 2 == 0 then by = by - (box_h / 2) elseif math.floor(t_win.alignment / 8) % 2 == 1 then by = by - box_h end

            local vx, vy = bx, by
            if t_win.bounds_type ~= obslua.OBS_BOUNDS_NONE then
                local ba = t_win.bounds_alignment
                if ba % 2 == 0 then vx = bx + (box_w - vis_w) / 2 elseif math.floor(ba / 2) % 2 == 1 then vx = bx + (box_w - vis_w) end
                if math.floor(ba / 4) % 2 == 0 then vy = by + (box_h - vis_h) / 2 elseif math.floor(ba / 8) % 2 == 1 then vy = by + (box_h - vis_h) end
            end

            -- 2. SYNC BROWSER SIZE
            local b_settings = obslua.obs_source_get_settings(source_browser)
            local target_w, target_h = math.floor(vis_w + pad_l + pad_r), math.floor(vis_h + pad_t + pad_b)
            
            if obslua.obs_data_get_int(b_settings, "width") ~= target_w or obslua.obs_data_get_int(b_settings, "height") ~= target_h then
                obslua.obs_data_set_int(b_settings, "width", target_w)
                obslua.obs_data_set_int(b_settings, "height", target_h)
                obslua.obs_source_update(source_browser, b_settings)
            end
            obslua.obs_data_release(b_settings)

            -- 3. SYNC BROWSER POSITION
            local t_bro = obslua.obs_transform_info()
            obslua.obs_sceneitem_get_info2(browser_item, t_bro)
            t_bro.alignment = 5 -- Top Left
            t_bro.bounds_type = 0
            t_bro.scale.x, t_bro.scale.y = 1.0, 1.0
            t_bro.pos.x, t_bro.pos.y = vx - pad_l, vy - pad_t
            obslua.obs_sceneitem_set_info2(browser_item, t_bro)
        end
    elseif browser_item then
        obslua.obs_sceneitem_set_visible(browser_item, false)
    end
    obslua.obs_source_release(current_scene_source)
end

function script_properties()
    local props = obslua.obs_properties_create()
    obslua.obs_properties_add_text(props, "source_windows_csv", "Target Windows (CSV):", obslua.OBS_TEXT_DEFAULT)
    obslua.obs_properties_add_text(props, "source_browser_name", "Browser Wrapper Name:", obslua.OBS_TEXT_DEFAULT)
    obslua.obs_properties_add_int(props, "pad_t", "Pad T", -1000, 1000, 1)
    obslua.obs_properties_add_int(props, "pad_b", "Pad B", -1000, 1000, 1)
    obslua.obs_properties_add_int(props, "pad_l", "Pad L", -1000, 1000, 1)
    obslua.obs_properties_add_int(props, "pad_r", "Pad R", -1000, 1000, 1)
    return props
end

function script_update(settings)
    source_windows_csv = obslua.obs_data_get_string(settings, "source_windows_csv")
    source_browser_name = obslua.obs_data_get_string(settings, "source_browser_name")
    pad_t = obslua.obs_data_get_int(settings, "pad_t")
    pad_b = obslua.obs_data_get_int(settings, "pad_b")
    pad_l = obslua.obs_data_get_int(settings, "pad_l")
    pad_r = obslua.obs_data_get_int(settings, "pad_r")
end

function script_load(settings)
    obslua.timer_add(update_wrap, 50)
end