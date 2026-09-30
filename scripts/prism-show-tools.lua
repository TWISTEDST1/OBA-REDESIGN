--[[
Prism Show Tools
  * On-air session timer: keeps a Text source updated with "LIVE 01:02:03" /
    "REC 00:12:45" while you stream or record.
  * Chapter markers: a hotkey drops a named chapter into the recording (native
    chapters for Hybrid MP4/MOV) and logs a YouTube-ready chapter list next to
    the recording file when recording stops.
  * Stream health: bitrate, dropped frames and FPS in a Text source.
  * Smart replay naming: saved replays are renamed to include the active scene.
]]

local obs = obslua

local timer_source_name = ""
local health_source_name = ""
local show_when_idle = false
local idle_text = ""
local chapter_prefix = "Chapter"
local write_chapter_file = true
local rename_replays = true

local rec_started_at = nil
local rec_paused_at = nil
local rec_paused_total = 0
local stream_started_at = nil
local chapters = {}
local marker_hotkey = obs.OBS_INVALID_HOTKEY_ID

-- ----------------------------------------------------------------------------
-- Helpers

local function fmt_duration(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

local function recording_elapsed()
	if rec_started_at == nil then
		return 0
	end
	local paused = rec_paused_total
	if rec_paused_at ~= nil then
		paused = paused + (os.time() - rec_paused_at)
	end
	return os.time() - rec_started_at - paused
end

local last_text = {}

local function set_text(source_name, text)
	if source_name == nil or source_name == "" or text == last_text[source_name] then
		return
	end
	last_text[source_name] = text
	local source = obs.obs_get_source_by_name(source_name)
	if source == nil then
		return
	end
	local data = obs.obs_data_create()
	obs.obs_data_set_string(data, "text", text)
	obs.obs_source_update(source, data)
	obs.obs_data_release(data)
	obs.obs_source_release(source)
end

local function current_scene_name()
	local scene = obs.obs_frontend_get_current_scene()
	if scene == nil then
		return "Scene"
	end
	local name = obs.obs_source_get_name(scene)
	obs.obs_source_release(scene)
	return name
end

local function sanitize(name)
	return (name:gsub('[<>:"/\\|%?%*]', "_"))
end

-- ----------------------------------------------------------------------------
-- Stream health (bitrate, dropped frames, render FPS)

local last_bytes = nil
local last_bytes_at = nil

local function health_text()
	local output = obs.obs_frontend_get_streaming_output()
	if output == nil then
		return ""
	end
	local text = ""
	if obs.obs_output_active(output) then
		local bytes = obs.obs_output_get_total_bytes(output)
		local now = obs.os_gettime_ns()
		local kbps = 0
		if last_bytes ~= nil and now > last_bytes_at and bytes >= last_bytes then
			kbps = (bytes - last_bytes) * 8 / ((now - last_bytes_at) / 1e9) / 1000
		end
		last_bytes, last_bytes_at = bytes, now

		local dropped = obs.obs_output_get_frames_dropped(output)
		local total = obs.obs_output_get_total_frames(output)
		local pct = total > 0 and (dropped / total * 100) or 0
		text = string.format("%d kbps  |  %.1f%% dropped (%d)  |  %.0f fps", kbps, pct, dropped, obs.obs_get_active_fps())
	else
		last_bytes, last_bytes_at = nil, nil
	end
	obs.obs_output_release(output)
	return text
end

-- ----------------------------------------------------------------------------
-- Session timer

local function tick()
	if health_source_name ~= "" then
		set_text(health_source_name, health_text())
	end

	local parts = {}
	if stream_started_at ~= nil then
		table.insert(parts, "LIVE " .. fmt_duration(os.time() - stream_started_at))
	end
	if rec_started_at ~= nil then
		local label = rec_paused_at ~= nil and "PAUSED " or "REC "
		table.insert(parts, label .. fmt_duration(recording_elapsed()))
	end

	if #parts > 0 then
		set_text(timer_source_name, table.concat(parts, "   "))
	elseif show_when_idle then
		set_text(timer_source_name, idle_text)
	else
		set_text(timer_source_name, "")
	end
end

-- ----------------------------------------------------------------------------
-- Chapters

local function add_chapter(name)
	if rec_started_at == nil then
		obs.script_log(obs.LOG_WARNING, "Chapter marker ignored: not recording")
		return
	end
	if name == nil or name == "" then
		name = string.format("%s %d", chapter_prefix, #chapters + 1)
	end

	-- Native chapter support (Hybrid MP4/MOV). Silently skipped for other formats.
	pcall(obs.obs_frontend_recording_add_chapter, name)

	local stamp = fmt_duration(recording_elapsed())
	table.insert(chapters, stamp .. " " .. name)
	obs.script_log(obs.LOG_INFO, "Chapter added: " .. stamp .. " " .. name)
end

local function on_marker_hotkey(pressed)
	if pressed then
		add_chapter(nil)
	end
end

local function write_chapters()
	if not write_chapter_file or #chapters <= 1 then
		return
	end
	local path = obs.obs_frontend_get_last_recording()
	if path == nil or path == "" then
		return
	end
	local out_path = path:gsub("%.[^%.\\/]+$", "") .. " - chapters.txt"
	local f = io.open(out_path, "w")
	if f == nil then
		obs.script_log(obs.LOG_WARNING, "Could not write chapter file: " .. out_path)
		return
	end
	f:write(table.concat(chapters, "\n"), "\n")
	f:close()
	obs.script_log(obs.LOG_INFO, "Chapter list saved: " .. out_path)
end

-- ----------------------------------------------------------------------------
-- Replay naming

local function rename_last_replay()
	if not rename_replays then
		return
	end
	local path = obs.obs_frontend_get_last_replay()
	if path == nil or path == "" then
		return
	end
	local dir, file = path:match("^(.*[\\/])([^\\/]+)$")
	if dir == nil then
		return
	end
	local new_path = dir .. sanitize(current_scene_name()) .. " - " .. file
	local ok, err = os.rename(path, new_path)
	if ok then
		obs.script_log(obs.LOG_INFO, "Replay saved as " .. new_path)
	else
		obs.script_log(obs.LOG_WARNING, "Could not rename replay: " .. tostring(err))
	end
end

-- ----------------------------------------------------------------------------
-- Frontend events

local function on_event(event)
	if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
		stream_started_at = os.time()
	elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
		stream_started_at = nil
	elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
		rec_started_at = os.time()
		rec_paused_at = nil
		rec_paused_total = 0
		chapters = { "00:00:00 Intro" }
	elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED then
		rec_paused_at = os.time()
	elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
		if rec_paused_at ~= nil then
			rec_paused_total = rec_paused_total + (os.time() - rec_paused_at)
		end
		rec_paused_at = nil
	elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
		write_chapters()
		rec_started_at = nil
		rec_paused_at = nil
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
		rename_last_replay()
	end
	tick()
end

-- ----------------------------------------------------------------------------
-- Script API

function script_description()
	return [[<h2>Prism Show Tools</h2>
<p>Session timer, recording chapter markers and smart replay names.</p>
<ul>
<li><b>Timer:</b> pick a Text source to show LIVE / REC time.</li>
<li><b>Chapters:</b> bind <i>Prism: Add chapter marker</i> in Settings → Hotkeys.
A YouTube-ready chapter list is saved next to the recording.</li>
<li><b>Replays:</b> saved replays get the active scene name prepended.</li>
</ul>]]
end

function script_properties()
	local props = obs.obs_properties_create()

	local list = obs.obs_properties_add_list(props, "timer_source", "Timer text source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(list, "(none)", "")
	local health = obs.obs_properties_add_list(props, "health_source", "Stream health text source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(health, "(none)", "")
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			local id = obs.obs_source_get_unversioned_id(source)
			if id == "text_gdiplus" or id == "text_ft2_source" then
				local name = obs.obs_source_get_name(source)
				obs.obs_property_list_add_string(list, name, name)
				obs.obs_property_list_add_string(health, name, name)
			end
		end
	end
	obs.source_list_release(sources)

	obs.obs_properties_add_bool(props, "show_when_idle", "Show text when off air")
	obs.obs_properties_add_text(props, "idle_text", "Off-air text", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "chapter_prefix", "Chapter name prefix", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_bool(props, "write_chapter_file", "Save chapter list (.txt) after recording")
	obs.obs_properties_add_bool(props, "rename_replays", "Prefix saved replays with scene name")
	obs.obs_properties_add_button(props, "add_marker", "Add chapter marker now", function()
		add_chapter(nil)
		return false
	end)

	return props
end

function script_defaults(settings)
	obs.obs_data_set_default_string(settings, "idle_text", "OFF AIR")
	obs.obs_data_set_default_string(settings, "chapter_prefix", "Chapter")
	obs.obs_data_set_default_bool(settings, "write_chapter_file", true)
	obs.obs_data_set_default_bool(settings, "rename_replays", true)
end

function script_update(settings)
	timer_source_name = obs.obs_data_get_string(settings, "timer_source")
	health_source_name = obs.obs_data_get_string(settings, "health_source")
	show_when_idle = obs.obs_data_get_bool(settings, "show_when_idle")
	idle_text = obs.obs_data_get_string(settings, "idle_text")
	chapter_prefix = obs.obs_data_get_string(settings, "chapter_prefix")
	write_chapter_file = obs.obs_data_get_bool(settings, "write_chapter_file")
	rename_replays = obs.obs_data_get_bool(settings, "rename_replays")
	last_text = {}
	tick()
end

function script_load(settings)
	marker_hotkey = obs.obs_hotkey_register_frontend("prism.chapter_marker", "Prism: Add chapter marker", on_marker_hotkey)
	local saved = obs.obs_data_get_array(settings, "prism.chapter_marker")
	obs.obs_hotkey_load(marker_hotkey, saved)
	obs.obs_data_array_release(saved)

	if obs.obs_frontend_streaming_active() then
		stream_started_at = os.time()
	end
	if obs.obs_frontend_recording_active() then
		rec_started_at = os.time()
		chapters = { "00:00:00 Intro" }
	end

	obs.obs_frontend_add_event_callback(on_event)
	obs.timer_add(tick, 1000)
end

function script_save(settings)
	local saved = obs.obs_hotkey_save(marker_hotkey)
	obs.obs_data_set_array(settings, "prism.chapter_marker", saved)
	obs.obs_data_array_release(saved)
end

function script_unload()
	obs.timer_remove(tick)
end
