-- This file needs to have same structure as nvconfig.lua 
-- https://github.com/NvChad/ui/blob/v3.0/lua/nvconfig.lua
-- Please read that file to know all available options :( 

---@type ChadrcConfig
local M = {}

M.base46 = {
	theme = "gruvbox",

	hl_override = {
		Comment = { fg = "#B0B0B0", italic = true,},
		["@comment"] = { fg = "#B0B0B0", italic = true },
	},

  transparency = true
}


return M
