-- installer.lua — mLua extension download, version management, and uninstall
--
-- The VS Code extension (.vsix) is extracted into javascript/msw.mlua-<version>/
-- inside the plugin directory, so the JS wrapper and the extension live together.

local M = {}

---@class InstallerConfig
---@field install_dir string Directory where versioned extension dirs are created (javascript/)
---@field publisher string Extension publisher id
---@field extension string Extension name id

---@type InstallerConfig
M.config = {
	-- javascript/ directory next to this file's plugin root
	-- Source file path: <plugin_root>/lua/mlua/installer.lua  → go up three levels → <plugin_root>
	install_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/javascript",
	publisher = "msw",
	extension = "mlua",
}

---Get the latest version from the VS Code marketplace
---@return string|nil version
function M.get_latest_version()
	local data = string.format(
		'{"filters":[{"criteria":[{"filterType":7,"value":"%s.%s"}]}],"flags":914}',
		M.config.publisher,
		M.config.extension
	)

	local curl_cmd
	if vim.fn.has("win32") == 1 then
		data = data:gsub('"', '\\"')
		curl_cmd = string.format(
			'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json;api-version=3.0-preview.1" -d "%s" "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"',
			data
		)
	else
		curl_cmd = string.format(
			"curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json;api-version=3.0-preview.1' -d '%s' 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery'",
			data
		)
	end

	local handle = io.popen(curl_cmd)
	if not handle then
		return nil
	end

	local result = handle:read("*a")
	handle:close()

	return result:match('"version":"([^"]+)"')
end

---Get the installed version and its directory
---@return string|nil version
---@return string|nil install_dir  Full path to the versioned extension directory
function M.get_installed_version()
	local pattern = M.config.install_dir
		.. "/"
		.. M.config.publisher
		.. "."
		.. M.config.extension
		.. "-*"
	local dirs = vim.fn.glob(pattern, false, true)

	if #dirs == 0 then
		return nil
	end

	table.sort(dirs)
	local latest_dir = dirs[#dirs]
	local version = latest_dir:match("%-([%d%.]+)$")
	return version, latest_dir
end

---Download and extract the mLua VS Code extension into javascript/
---@param version string|nil Version to download (defaults to latest)
---@return boolean success
---@return string|nil extract_dir  Directory where the extension was extracted
function M.download(version)
	version = M.get_latest_version() or "1.1.4"

	if not version then
		vim.notify("Error: Could not fetch version", vim.log.levels.ERROR)
		return false
	end

	vim.notify("Downloading mLua v" .. version .. "...", vim.log.levels.INFO)

	local download_dir = M.config.install_dir
	local extension_name = M.config.publisher .. "." .. M.config.extension .. "-" .. version
	local vsix_file = download_dir .. "/" .. extension_name .. ".vsix"
	local zip_file = download_dir .. "/" .. extension_name .. ".zip"
	local extract_dir = download_dir .. "/" .. extension_name

	vim.fn.mkdir(download_dir, "p")

	local download_url = string.format(
		"https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/%s/extension/%s/%s/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage",
		M.config.publisher,
		M.config.publisher,
		M.config.extension,
		version
	)

	local download_cmd = string.format('curl -L -o "%s" "%s"', vsix_file, download_url)
	if os.execute(download_cmd) ~= 0 then
		vim.notify("Error: Download failed", vim.log.levels.ERROR)
		return false
	end

	os.rename(vsix_file, zip_file)
	vim.fn.mkdir(extract_dir, "p")

	local extract_cmd
	if vim.fn.has("win32") == 1 then
		extract_cmd = string.format(
			"powershell -Command \"Expand-Archive -Path '%s' -DestinationPath '%s' -Force\"",
			zip_file:gsub("/", "\\"),
			extract_dir:gsub("/", "\\")
		)
	else
		extract_cmd = string.format('unzip -q -o "%s" -d "%s"', zip_file, extract_dir)
	end

	os.execute(extract_cmd)
	os.remove(zip_file)

	vim.notify("mLua v" .. version .. " installed to " .. extract_dir, vim.log.levels.INFO)
	return true, extract_dir
end

---Update to the latest version (removes old version after successful download)
function M.update()
	local latest_version = M.get_latest_version()
	local installed_version, installed_dir = M.get_installed_version()

	if not latest_version then
		vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
		return
	end

	if not installed_version then
		vim.notify("mLua not installed. Installing v" .. latest_version .. "...", vim.log.levels.INFO)
		M.download(latest_version)
		return
	end

	vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
	vim.notify("Latest:    v" .. latest_version, vim.log.levels.INFO)

	if installed_version == latest_version then
		vim.notify("Already up to date!", vim.log.levels.INFO)
		return
	end

	local confirm = vim.fn.confirm(
		string.format("Update mLua from v%s to v%s?", installed_version, latest_version),
		"&Yes\n&No",
		2
	)
	if confirm ~= 1 then
		vim.notify("Update cancelled", vim.log.levels.INFO)
		return
	end

	local success = M.download(latest_version)
	if success then
		vim.notify("Removing old version...", vim.log.levels.INFO)
		local rm_cmd
		if vim.fn.has("win32") == 1 then
			rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
		else
			rm_cmd = string.format('rm -rf "%s"', installed_dir)
		end
		os.execute(rm_cmd)
		vim.notify("Update complete! Restart Neovim to use the new version.", vim.log.levels.WARN)
	end
end

---Print installed vs latest version information
function M.check_version()
	local latest_version = M.get_latest_version()
	local installed_version = M.get_installed_version()

	if not latest_version then
		vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
		return
	end

	if not installed_version then
		vim.notify("mLua is not installed", vim.log.levels.WARN)
		vim.notify("Latest available: v" .. latest_version, vim.log.levels.INFO)
		vim.notify("Run :Mlua install to install", vim.log.levels.INFO)
		return
	end

	vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
	vim.notify("Latest:    v" .. latest_version, vim.log.levels.INFO)

	if installed_version ~= latest_version then
		vim.notify("Update available! Run :Mlua update to upgrade", vim.log.levels.WARN)
	else
		vim.notify("You have the latest version!", vim.log.levels.INFO)
	end
end

---Remove the installed extension directory
function M.uninstall()
	local installed_version, installed_dir = M.get_installed_version()

	if not installed_version then
		vim.notify("mLua is not installed", vim.log.levels.WARN)
		return
	end

	local confirm = vim.fn.confirm(
		string.format("Uninstall mLua v%s?", installed_version),
		"&Yes\n&No",
		2
	)
	if confirm ~= 1 then
		vim.notify("Uninstall cancelled", vim.log.levels.INFO)
		return
	end

	local rm_cmd
	if vim.fn.has("win32") == 1 then
		rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
	else
		rm_cmd = string.format('rm -rf "%s"', installed_dir)
	end

	os.execute(rm_cmd)
	vim.notify("mLua v" .. installed_version .. " uninstalled", vim.log.levels.INFO)
end

return M
