-- license:BSD-3-Clause
-- copyright-holders:MAMEdev Team
---------------------------------------------------------------------------
--
--   gamepouch.lua
--
--   Trimmed MAME target for GamePouch.
--
--   Only the manufacturer folders that carry the arcade drivers referenced
--   by GamePouch's multiplayer catalog are compiled:
--       snk    -> NeoGeo (kof / mslug / samsho / ...)
--       capcom -> CPS1 / CPS2 (sf2 / ddsom / punisher / 1941 / ...)
--   plus `shared`, which must always be linked last.
--
--   Use: make -f Makefile.libretro SUBTARGET=gamepouch platform=android-arm64
--
---------------------------------------------------------------------------

local function selectors_get(path)
	local selector = ""
	for l in io.lines(path) do
		if l:sub(1, 3) == "--@" then
			local pos = l:find(",")
			selector = selector .. l:sub(pos+1) .. "\n"
		end
	end
	return selector
end

local selectors =
		selectors_get(MAME_DIR .. "scripts/src/cpu.lua") ..
		selectors_get(MAME_DIR .. "scripts/src/sound.lua") ..
		selectors_get(MAME_DIR .. "scripts/src/video.lua") ..
		selectors_get(MAME_DIR .. "scripts/src/machine.lua") ..
		selectors_get(MAME_DIR .. "scripts/src/bus.lua") ..
		selectors_get(MAME_DIR .. "scripts/src/formats.lua")

load(selectors)()

-- Manufacturer folders to compile. Keep in sync with src/mame/gamepouch.lst
-- (regenerate both from app/assets/data/multiplayer.json).
local GAMEPOUCH_FOLDERS = { "capcom", "snk" }

-- `shared` is not a manufacturer but provides code the drivers depend on.
local function gamepouch_build_folders()
	local t = {}
	for _, n in pairs(GAMEPOUCH_FOLDERS) do table.insert(t, n) end
	table.insert(t, "shared")
	return t
end

function linkProjects_mame_gamepouch(_target, _subtarget)
	local projects = {}
	for x, name in pairs(GAMEPOUCH_FOLDERS) do
		local dir = path.join(MAME_DIR, "src", _target, name)
		if 0 < #os.matchfiles(path.join(dir, "**.cpp")) then
			table.insert(projects, name)
		elseif 0 < #os.matchfiles(path.join(dir, "**.h")) then
			table.insert(projects, name)
		elseif 0 < #os.matchfiles(path.join(dir, "**.ipp")) then
			table.insert(projects, name)
		end
	end
	table.sort(projects)
	table.insert(projects, "shared") -- must stay at the end
	links(projects)
end

function createMAMEProjects(_target, _subtarget, _name)
	project (_name)
	targetsubdir(_target .."_" .. _subtarget)
	kind (LIBTYPE)
	uuid (os.uuid("drv-" .. _target .."_" .. _subtarget .. "_" .._name))
	addprojectflags()
	precompiledheaders_novs()

	includedirs {
		MAME_DIR .. "src/osd",
		MAME_DIR .. "src/emu",
		MAME_DIR .. "src/devices",
		MAME_DIR .. "src/mame/shared",
		MAME_DIR .. "src/lib",
		MAME_DIR .. "src/lib/util",
		MAME_DIR .. "3rdparty",
		GEN_DIR  .. "mame/layout",
	}

	includedirs {
		ext_includedir("asio"),
		ext_includedir("flac"),
		ext_includedir("glm"),
		ext_includedir("jpeg"),
		ext_includedir("rapidjson"),
		ext_includedir("zlib")
	}

end

function createProjects_mame_gamepouch(_target, _subtarget)
	for x, name in pairs(gamepouch_build_folders()) do
		local dir = path.join(MAME_DIR, "src", _target, name)

		local sources = {}
		if 0 < #os.matchfiles(path.join(dir, "**.cpp")) then
			table.insert(sources, MAME_DIR .. "src/" .. _target .. "/" .. name .. "/**.cpp")
		end
		if 0 < #os.matchfiles(path.join(dir, "**.h")) then
			table.insert(sources, MAME_DIR .. "src/" .. _target .. "/" .. name .. "/**.h")
		end
		if 0 < #os.matchfiles(path.join(dir, "**.ipp")) then
			table.insert(sources, MAME_DIR .. "src/" .. _target .. "/" .. name .. "/**.ipp")
		end

		if 0 < #sources then
			createMAMEProjects(_target, _subtarget, name)
			table.sort(sources)
			files(sources)
		end
	end
end
