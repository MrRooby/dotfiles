require "nvchad.autocmds"

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "tex", "plaintex", "bib"},
  callback = function()
    -- vim.opt_local.spell = false
    -- vim.opt_local.spelllang = {"en", "pl"}
    vim.opt_local.expandtab = true
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
  end,
})

