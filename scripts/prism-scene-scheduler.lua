--[[
Prism Scene Scheduler
  * Countdown: shows a "Starting in 04:59" countdown in a Text source and
    switches to your main scene when it reaches zero. Optionally starts
    streaming at zero.
  * Timed switches: switch to a scene at a set time of day (HH:MM), e.g. an
    "Intermission" scene at 20:30.
]]

local obs = obslua

local SCHEDULE_SLOTS = 3

local text_source_name = ""
local countdown_minutes = 5
local countdown_prefix = "Starting in "
local finished_text = "Starting now!"
local target_scene = ""
local start_stream_at_zero = false
local schedule = {}

local countdown_end = nil
local last_fired = {}
local start_hotkey = obs.OBS_INVALID_HOTKEY_ID

-- ----------------------------------------------------------------------------
-- Helpers

local function set_text(text)
	if text_source_name == "" then
		return
	end
	local source = obs.obs_get_source_by_name(text_source_name)
	if source == nil then
		return
	end
	local data = obs.obs_data_create()
	obs.obs_data_set_string(data, "text", text)
	obs.obs_source_update(source, data)
	obs.obs_data_release(data)
	obs.obs_source_release(source)
end

local function switch_to_scene(name)
	if name == nil or name == "" then
		return
	end
	local source = obs.obs_get_source_by_name(name)
	if source == nil then
		obs.script_log(obs.LOG_WARNING, "Scene not found: " .. name)
		return
	end
	obs.obs_frontend_set_current_scene(source)
	obs.obs_source_release(source)
	obs.script_log(obs.LOG_INFO, "Switched to scene: " .. name)
end

local function fmt_mmss(seconds)
	seconds = math.max(0, seconds)
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function add_scene_list(props, key, label)
	local list = obs.obs_properties_add_list(props, key, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(list, "(none)", "")
	local scenes = obs.obs_frontend_get_scene_names()
	if scenes ~= nil then
		for _, name in ipairs(scenes) do
			obs.obs_property_list_add_string(list, name, name)
		end
	end
	return list
end

-- ----------------------------------------------------------------------------
-- Countdown

local function tick()
	-- Countdown
	if countdown_end ~= nil then
		local remaining = countdown_end - os.time()
		if remaining > 0 then
			set_text(countdown_prefix .. fmt_mmss(remaining))
		else
			countdown_end = nil
			set_text(finished_text)
			switch_to_scene(target_scene)
			if start_stream_at_zero and not obs.obs_frontend_streaming_active() then
				obs.obs_frontend_streaming_start()
			end
		end
	end

	-- Time-of-day switches
	local now = os.date("%H:%M")
	local today = os.date("%Y-%m-%d")
	for i, slot in ipairs(schedule) do
		if slot.enabled and slot.time == now and last_fired[i] ~= today .. now then
			last_fired[i] = today .. now
			switch_to_scene(slot.scene)
		end
	end
end

local function start_countdown()
	countdown_end = os.time() + math.floor(countdown_minutes * 60)
	tick()
	obs.script_log(obs.LOG_INFO, string.format("Countdown started: %d min", countdown_minutes))
end

local function stop_countdown()
	countdown_end = nil
	set_text("")
end

local function on_start_hotkey(pressed)
	if pressed then
		start_countdown()
	end
end

-- ----------------------------------------------------------------------------
-- Script API

function script_description()
	return [[<h2>Prism Scene Scheduler</h2>
<p>Run a <b>Starting soon</b> countdown that switches to your main scene
(and can go live) at zero, and schedule scene switches by time of day.</p>
<p>Hotkey: <i>Prism: Start countdown</i> in Settings → Hotkeys.</p>]]
end

function script_properties()
	local props = obs.obs_properties_create()

	local list = obs.obs_properties_add_list(props, "text_source", "Countdown text source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(list, "(none)", "")
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			local id = obs.obs_source_get_unversioned_id(source)
			if id == "text_gdiplus" or id == "text_ft2_source" then
				local name = obs.obs_source_get_name(source)
				obs.obs_property_list_add_string(list, name, name)
			end
		end
	end
	obs.source_list_release(sources)

	obs.obs_properties_add_int(props, "countdown_minutes", "Countdown length (minutes)", 1, 180, 1)
	obs.obs_properties_add_text(props, "countdown_prefix", "Countdown label", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "finished_text", "Text at zero", obs.OBS_TEXT_DEFAULT)
	add_scene_list(props, "target_scene", "Switch to scene at zero")
	obs.obs_properties_add_bool(props, "start_stream_at_zero", "Start streaming at zero")

	obs.obs_properties_add_button(props, "start_btn", "▶  Start countdown", function()
		start_countdown()
		return false
	end)
	obs.obs_properties_add_button(props, "stop_btn", "■  Stop countdown", function()
		stop_countdown()
		return false
	end)

	for i = 1, SCHEDULE_SLOTS do
		local group = obs.obs_properties_create()
		obs.obs_properties_add_text(group, "sched_time_" .. i, "Time (HH:MM, 24h)", obs.OBS_TEXT_DEFAULT)
		add_scene_list(group, "sched_scene_" .. i, "Scene")
		obs.obs_properties_add_group(props, "sched_" .. i, "Timed switch " .. i, obs.OBS_GROUP_CHECKABLE, group)
	end

	return props
end

function script_defaults(settings)
	obs.obs_data_set_default_int(settings, "countdown_minutes", 5)
	obs.obs_data_set_default_string(settings, "countdown_prefix", "Starting in ")
	obs.obs_data_set_default_string(settings, "finished_text", "Starting now!")
end

function script_update(settings)
	text_source_name = obs.obs_data_get_string(settings, "text_source")
	countdown_minutes = obs.obs_data_get_int(settings, "countdown_minutes")
	countdown_prefix = obs.obs_data_get_string(settings, "countdown_prefix")
	finished_text = obs.obs_data_get_string(settings, "finished_text")
	target_scene = obs.obs_data_get_string(settings, "target_scene")
	start_stream_at_zero = obs.obs_data_get_bool(settings, "start_stream_at_zero")

	schedule = {}
	for i = 1, SCHEDULE_SLOTS do
		local time = obs.obs_data_get_string(settings, "sched_time_" .. i)
		local h, m = time:match("^%s*(%d%d?):(%d%d)%s*$")
		table.insert(schedule, {
			enabled = obs.obs_data_get_bool(settings, "sched_" .. i) and h ~= nil,
			time = h and string.format("%02d:%s", tonumber(h), m) or "",
			scene = obs.obs_data_get_string(settings, "sched_scene_" .. i),
		})
	end
end

function script_load(settings)
	start_hotkey = obs.obs_hotkey_register_frontend("prism.start_countdown", "Prism: Start countdown", on_start_hotkey)
	local saved = obs.obs_data_get_array(settings, "prism.start_countdown")
	obs.obs_hotkey_load(start_hotkey, saved)
	obs.obs_data_array_release(saved)
	obs.timer_add(tick, 1000)
end

function script_save(settings)
	local saved = obs.obs_hotkey_save(start_hotkey)
	obs.obs_data_set_array(settings, "prism.start_countdown", saved)
	obs.obs_data_array_release(saved)
end

function script_unload()
	obs.timer_remove(tick)
end
