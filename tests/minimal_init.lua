vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(assert(vim.env.PLENARY_PATH))
vim.cmd("runtime plugin/plenary.vim")
vim.opt.rtp:append(assert(vim.env.DAP_PATH))
