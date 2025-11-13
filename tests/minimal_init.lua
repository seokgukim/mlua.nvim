local mlua_nvim_dir = os.getenv("MLUA_NEVIM_DIR") or "/tmp/mlua.nvim"
local is_not_a_directory = vim.fn.isdirectory(mlua_nvim_dir) == 0
if is_not_a_directory then
	vim.fn.system({ "git", "clone", "https://github.com/seokgukim/mlua.nvim", mlua_nvim_dir })
end

print("Using mlua.nvim from:", mlua_nvim_dir)
local result, err = pcall(function()
	vim.opt.runtimepath:prepend(mlua_nvim_dir)
	require("mlua").setup({})
end)

print("mlua.nvim setup result:", result, err)
