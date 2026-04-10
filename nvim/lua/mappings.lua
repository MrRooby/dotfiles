require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- Custom mine
map("n", "<leader>E", ":NvimTreeToggle<CR>", {desc = "Toggle NvimTree"})
map('t', '<Esc>', [[<C-\><C-n>]], { desc = "Exit terminal mode" })
map("n", "<leader>tt", function()
  require("nvchad.term").toggle { pos = "sp", id = "htoggleTerm" , size = 0.2}
end, { desc = "Terminal Toggle Horizontal" })

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
