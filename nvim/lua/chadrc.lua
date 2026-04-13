-- ---@type ChadrcConfig
-- local M = {}
--
-- M.base46 = {
-- 	theme = "gruvbox",
--
-- 	hl_override = {
-- 		Comment = { fg = "#B0B0B0", italic = true,},
-- 		["@comment"] = { fg = "#B0B0B0", italic = true },
-- 	},
--
--   transparency = true
-- }
--
--
-- return M


---@type ChadrcConfig
local M = {}

M.base46 = {
  theme = "gruvbox",
  -- Transparency must be inside base46 in recent NvChad versions
  transparency = true,

  hl_override = {
    Comment = { fg = "#B0B0B0", italic = true },
    ["@comment"] = { fg = "#B0B0B0", italic = true },
  },

  hl_add = {
    -- Fixes the "everything is one color" issue by linking LSP tokens to theme colors
    ["@lsp.type.parameter"] = { link = "@variable.parameter" },
    ["@lsp.type.variable"] = { link = "@variable" },
    
    -- Ensures 'const', 'return', 'bool' keep their distinct colors
    ["@lsp.type.keyword"] = { link = "@keyword" },
    ["@lsp.type.type"] = { link = "@type" },
    ["@lsp.type.modifier"] = { link = "@keyword.modifier" }, -- This usually handles 'const'
  },
}

-- This block ensures the UI honors the transparency
M.ui = {
  transparency = true,
}

return M
