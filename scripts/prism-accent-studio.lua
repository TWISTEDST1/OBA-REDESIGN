--[[
Prism Accent Studio
  Pick one accent colour (or a preset) and generate a personal "Prism Custom"
  theme built on Prism (dark) or Prism Light. Hover, pressed, tint and edge
  shades are derived automatically so the palette stays balanced, and text on
  accent buttons switches between dark and white for readability.
  Afterwards select it under Settings -> Appearance -> Theme.
]]

local obs = obslua

local PRESETS = {
	{ "Signal Amber (default)", 0xF28C28 },
	{ "Broadcast Blue", 0x3E8EF7 },
	{ "Emerald", 0x22C55E },
	{ "Gold", 0xE8B931 },
	{ "Mono Silver", 0xC9CDD3 },
}

-- Accent family in each source theme: hex -> how to derive it from the accent.
--   { "base" }                 the accent itself
--   { "white" | "black", t }   accent mixed towards white/black by t
--   { "tint", t }              accent laid over the panel colour at opacity t
local DARK_MAP = {
	["#F28C28"] = { "base" },
	["#F59A3E"] = { "white", 0.10 },
	["#E57E1C"] = { "black", 0.06 },
	["#C86A12"] = { "black", 0.18 },
	["#FFA650"] = { "white", 0.18 },
	["#FFB070"] = { "white", 0.32 },
	["#423122"] = { "tint", 0.18 },
	["#533A23"] = { "tint", 0.26 },
	["#2A241E"] = { "tint", 0.08 },
}
local DARK_PANEL = { 0x1B, 0x1D, 0x21 }

local LIGHT_MAP = {
	["#E2761B"] = { "base" },
	["#EC8A34"] = { "white", 0.10 },
	["#D06812"] = { "black", 0.08 },
	["#B35A0E"] = { "black", 0.22 },
	["#F29440"] = { "white", 0.18 },
	["#FBECDF"] = { "tint", 0.14 },
	["#F9E1CD"] = { "tint", 0.22 },
}
local LIGHT_PANEL = { 0xFF, 0xFF, 0xFF }

local ON_ACCENT_TEXT = "#1A1206"

local accent = 0 -- set by script_update
local base_light = false

-- ----------------------------------------------------------------------------
-- Colour helpers. OBS colour properties are 0xAABBGGRR.

local function obs_to_rgb(c)
	return c % 256, math.floor(c / 256) % 256, math.floor(c / 65536) % 256
end

local function hex_to_obs(v)
	local r, g, b = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
	return 0xFF000000 + b * 65536 + g * 256 + r
end

local function mix(r, g, b, tr, tg, tb, amount)
	local function m(c, t)
		return math.floor(c + (t - c) * amount + 0.5)
	end
	return m(r, tr), m(g, tg), m(b, tb)
end

local function to_hex(r, g, b)
	return string.format("#%02X%02X%02X", r, g, b)
end

local function luminance(r, g, b)
	return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

local function themes_dir()
	local appdata = os.getenv("APPDATA")
	if appdata ~= nil then
		return appdata .. "\\obs-studio\\themes\\"
	end

	-- macOS and Linux: use whichever user theme folder already holds Prism
	local home = os.getenv("HOME") or ""
	local candidates = {
		home .. "/Library/Application Support/obs-studio/themes/",
		home .. "/.config/obs-studio/themes/",
	}
	for _, dir in ipairs(candidates) do
		local f = io.open(dir .. "Yami_Prism.ovt", "r")
		if f ~= nil then
			f:close()
			return dir
		end
	end
	return candidates[2]
end

local function plain_replace(s, find, repl)
	local i, j = s:find(find, 1, true)
	if i == nil then
		return s
	end
	return s:sub(1, i - 1) .. repl .. s:sub(j + 1)
end

-- ----------------------------------------------------------------------------
-- Theme generation

local function generate()
	local dir = themes_dir()
	local src_name = base_light and "Yami_PrismLight.ovt" or "Yami_Prism.ovt"
	local f = io.open(dir .. src_name, "r")
	if f == nil then
		obs.script_log(obs.LOG_WARNING, "Could not find " .. src_name .. " in " .. dir)
		return
	end
	local content = f:read("*a")
	f:close()

	local r, g, b = obs_to_rgb(accent)
	local map, panel = DARK_MAP, DARK_PANEL
	if base_light then
		-- Deepen slightly so the accent keeps contrast on white panels
		r, g, b = mix(r, g, b, 0, 0, 0, 0.07)
		map, panel = LIGHT_MAP, LIGHT_PANEL
	end

	for hex, rule in pairs(map) do
		local nr, ng, nb = r, g, b
		if rule[1] == "white" then
			nr, ng, nb = mix(r, g, b, 255, 255, 255, rule[2])
		elseif rule[1] == "black" then
			nr, ng, nb = mix(r, g, b, 0, 0, 0, rule[2])
		elseif rule[1] == "tint" then
			nr, ng, nb = mix(panel[1], panel[2], panel[3], r, g, b, rule[2])
		end
		content = content:gsub(hex, to_hex(nr, ng, nb))
	end

	if luminance(r, g, b) < 0.55 then
		content = content:gsub(ON_ACCENT_TEXT, "#FFFFFF")
	end

	if base_light then
		content = plain_replace(content, "name: 'Prism Light';", "name: 'Prism Custom';")
		content = plain_replace(content, "id: 'com.obsproject.Yami.PrismLight';", "id: 'com.obsproject.Yami.PrismCustom';")
	else
		content = plain_replace(content, "name: 'Prism';", "name: 'Prism Custom';")
		content = plain_replace(content, "id: 'com.obsproject.Yami.Prism';", "id: 'com.obsproject.Yami.PrismCustom';")
	end

	local out = io.open(dir .. "Yami_PrismCustom.ovt", "w")
	if out == nil then
		obs.script_log(obs.LOG_WARNING, "Could not write theme to " .. dir)
		return
	end
	out:write(content)
	out:close()

	obs.script_log(obs.LOG_INFO, "Generated Prism Custom (" .. to_hex(r, g, b) .. "). Select it in Settings > Appearance.")
end

-- ----------------------------------------------------------------------------
-- Script API

function script_description()
	return [[<h2>Prism Accent Studio</h2>
<p>Choose an accent colour (or a preset) and click <b>Generate theme</b>.
Then open <b>Settings -> Appearance</b> and pick <b>Prism Custom</b>.
If it is already selected, switch to another theme and back to reload it.</p>]]
end

function script_properties()
	local props = obs.obs_properties_create()

	local preset = obs.obs_properties_add_list(props, "preset", "Preset", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(preset, "(custom)", 0)
	for i, p in ipairs(PRESETS) do
		obs.obs_property_list_add_int(preset, p[1], i)
	end
	obs.obs_property_set_modified_callback(preset, function(ps, prop, settings)
		local p = PRESETS[obs.obs_data_get_int(settings, "preset")]
		if p ~= nil then
			obs.obs_data_set_int(settings, "accent", hex_to_obs(p[2]))
		end
		return true
	end)

	obs.obs_properties_add_color(props, "accent", "Accent colour")
	obs.obs_properties_add_bool(props, "base_light", "Light base (Prism Light)")
	obs.obs_properties_add_button(props, "generate", "Generate theme", function()
		generate()
		return false
	end)

	return props
end

function script_defaults(settings)
	obs.obs_data_set_default_int(settings, "accent", hex_to_obs(PRESETS[1][2]))
end

function script_update(settings)
	accent = obs.obs_data_get_int(settings, "accent")
	base_light = obs.obs_data_get_bool(settings, "base_light")
end
