local uv = vim.loop or vim.uv
local utils = require('mlua.utils')

local M = {}

local project_entry_cache = {}

local entry_glob_pattern = "**/*.{map,ui,model,collisiongroupset}"

local function parse_component_items(json_components)
  if not utils.is_list(json_components) then
    return {}
  end

  local items = {}
  for _, component in ipairs(json_components) do
    if type(component) == "table" then
      table.insert(items, {
        name = component["@type"],
        enable = component.enable,
      })
    end
  end

  return items
end

local function parse_entity_items(json_entities)
  if not utils.is_list(json_entities) then
    return {}
  end

  local entities = {}
  for _, entity in ipairs(json_entities) do
    if type(entity) == "table" then
      local summary = entity.jsonString or {}
      table.insert(entities, {
        id = entity.id,
        path = entity.path,
        name = summary.name,
        enable = summary.enable,
        visible = summary.visible,
        modelId = summary.modelId,
        components = parse_component_items(summary["@components"]),
      })
    end
  end

  return entities
end

local function parse_map_content_proto(content)
  if type(content) ~= "table" then
    return nil
  end

  local entities = parse_entity_items(content.Entities)
  return { entities = entities }
end

local function parse_ui_content_proto(content)
  return parse_map_content_proto(content)
end

local function parse_model_content_proto(content)
  if type(content) ~= "table" then
    return nil
  end

  local model = content.Json
  if type(model) ~= "table" then
    return nil
  end

  return {
    modelItem = {
      name = model.Name,
      id = model.Id,
      baseModelId = model.BaseModelId,
      components = model.Components,
    },
  }
end

local function parse_collision_group_set_proto(content)
  if type(content) ~= "table" then
    return nil
  end

  local json = content.Json
  if type(json) ~= "table" then
    return nil
  end

  local groups = {}
  if utils.is_list(json.Groups) then
    for _, group in ipairs(json.Groups) do
      if type(group) == "table" then
        table.insert(groups, {
          id = group.Id,
          name = group.Name,
        })
      end
    end
  end

  return {
    collisionGroupSet = {
      groups = groups,
    },
  }
end

local function build_entry_item(path, payload)
  if type(payload) ~= "table" then
    return nil
  end

  local entry_key = payload.EntryKey or payload.entryKey
  local content_type = payload.ContentType or payload.contentType
  local content_proto = payload.ContentProto or payload.contentProto

  if not entry_key or not content_type or not content_proto then
    return nil
  end

  local parsed
  if content_type == "x-mod/map" then
    parsed = parse_map_content_proto(content_proto)
  elseif content_type == "x-mod/ui" then
    parsed = parse_ui_content_proto(content_proto)
  elseif content_type == "x-mod/model" then
    parsed = parse_model_content_proto(content_proto)
  elseif content_type == "x-mod/collisiongroupset" then
    parsed = parse_collision_group_set_proto(content_proto)
  else
    return nil
  end

  if not parsed then
    return nil
  end

  return {
    uri = vim.uri_from_fname(path),
    entryKey = entry_key,
    contentType = content_type,
    contentProto = parsed,
  }
end

local function load_entry_file(path)
  if not path or path == '' then
    return nil
  end

  local content = select(1, utils.read_file_state(path))
  if not content then
    return nil
  end

  local payload = utils.json_decode(content)
  if not payload then
    return nil
  end

  local ok, result = pcall(build_entry_item, path, payload)
  if not ok then
    vim.notify_once(string.format("Failed to parse entry file %s: %s", path, result), vim.log.levels.WARN)
    return nil
  end

  return result
end

-- Default entry items are already in predefines, no need to load separately

-- Schema version must match what the LSP server expects
local CACHE_SCHEMA_VERSION = 2

local function load_cached_entry_items(installed_dir, root_dir)
  local cache_file = utils.build_project_cache_path(installed_dir, root_dir, "entry-items.json")
  if not cache_file then
    return nil
  end

  local payload = utils.read_text_file(cache_file)
  if not payload or payload == '' then
    return nil
  end

  local decoded = utils.json_decode(payload)
  if type(decoded) ~= "table" then
    return nil
  end

  if decoded.schemaVersion ~= CACHE_SCHEMA_VERSION then
    return nil
  end

  local items = decoded.items
  local sources = decoded.sources

  if not utils.is_list(items) then
    return nil
  end

  -- Validate sources if present
  if utils.is_list(sources) then
    local lookup = {}
    local lookup_count = 0
    for _, source in ipairs(sources) do
      if type(source) == "table" and source.path then
        lookup[source.path] = source.mtime
        lookup_count = lookup_count + 1
      end
    end

    local current = vim.fn.globpath(root_dir, entry_glob_pattern, false, true)
    if #current ~= lookup_count then
      return nil
    end

    for _, path in ipairs(current) do
      local recorded_mtime = lookup[path]
      if not recorded_mtime then
        return nil
      end

      -- Validate file modification time
      if uv and uv.fs_stat then
        local stat = uv.fs_stat(path)
        if not stat or not stat.mtime or stat.mtime.sec ~= recorded_mtime then
          return nil
        end
      end
    end
  end

  return items
end

local function store_cached_entry_items(installed_dir, root_dir, items, sources)
  local cache_file = utils.build_project_cache_path(installed_dir, root_dir, "entry-items.json")
  if not cache_file then
    return
  end

  local payload = {
    schemaVersion = CACHE_SCHEMA_VERSION,
    items = items,
    sources = sources,
  }

  local encoded = utils.json_encode(payload)
  if not encoded then
    return
  end

  utils.write_text_file(cache_file, encoded)
end

local function get_cached_project_items(root_dir)
  local cached = project_entry_cache[root_dir]
  if cached == nil then
    return nil
  end

  if utils.is_list(cached) then
    -- legacy cache shape (pre schema versioning)
    project_entry_cache[root_dir] = nil
    return nil
  end

  if type(cached) ~= "table" or type(cached.items) ~= "table" then
    project_entry_cache[root_dir] = nil
    return nil
  end

  if cached.schemaVersion ~= CACHE_SCHEMA_VERSION then
    project_entry_cache[root_dir] = nil
    return nil
  end

  return cached.items
end

local function set_cached_project_items(root_dir, items)
  if not root_dir or root_dir == '' then
    return
  end

  project_entry_cache[root_dir] = {
    schemaVersion = CACHE_SCHEMA_VERSION,
    items = items,
  }
end

-- Async version of collect_entry_items
function M.collect_entry_items_async(installed_dir, root_dir, callback)
  if not root_dir or root_dir == '' then
    callback({})
    return
  end

  root_dir = vim.fn.fnamemodify(root_dir, ':p')

  -- Try to get from memory cache first
  local project_items = get_cached_project_items(root_dir)
  if project_items then
    callback(project_items)
    return
  end

  -- Try to load from disk cache
  vim.schedule(function()
    local cached_items = load_cached_entry_items(installed_dir, root_dir)
    if cached_items then
      set_cached_project_items(root_dir, cached_items)
      callback(cached_items)
      return
    end

    -- Build from scratch asynchronously
    local files = vim.fn.globpath(root_dir, entry_glob_pattern, false, true)
    local project_items_new = {}
    local sources = {}
    local completed = 0
    local total = #files

    if total == 0 then
      set_cached_project_items(root_dir, {})
      callback({})
      return
    end

    for _, path in ipairs(files) do
      local normalized_path = vim.fn.fnamemodify(path, ':p')
      
      vim.schedule(function()
        if vim.fn.filereadable(normalized_path) == 1 then
          local entry = load_entry_file(normalized_path)
          if entry then
            table.insert(project_items_new, entry)
            if uv and uv.fs_stat then
              local stat = uv.fs_stat(normalized_path)
              if stat and stat.mtime then
                table.insert(sources, {
                  path = normalized_path,
                  mtime = stat.mtime.sec
                })
              end
            end
          end
        end

        completed = completed + 1
        if completed == total then
          -- Store to disk cache if we have items
          if #project_items_new > 0 then
            store_cached_entry_items(installed_dir, root_dir, project_items_new, sources)
          end

          -- Store to memory cache
          set_cached_project_items(root_dir, project_items_new)
          callback(project_items_new)
        end
      end)
    end
  end)
end

function M.collect_entry_items(installed_dir, root_dir, document_items)
  if not root_dir or root_dir == '' then
    return {}
  end

  root_dir = vim.fn.fnamemodify(root_dir, ':p')

  -- Try to get from memory cache first
  local project_items = get_cached_project_items(root_dir)
  if not project_items then
    -- Try to load from disk cache
    project_items = load_cached_entry_items(installed_dir, root_dir)
    local sources

    if not project_items then
      -- Build from scratch
      local files = vim.fn.globpath(root_dir, entry_glob_pattern, false, true)
      project_items = {}
      sources = {}

      for _, path in ipairs(files) do
        local normalized_path = vim.fn.fnamemodify(path, ':p')
        if vim.fn.filereadable(normalized_path) == 1 then
          local entry = load_entry_file(normalized_path)
          if entry then
            table.insert(project_items, entry)
            if uv and uv.fs_stat then
              local stat = uv.fs_stat(normalized_path)
              if stat and stat.mtime then
                table.insert(sources, {
                  path = normalized_path,
                  mtime = stat.mtime.sec
                })
              end
            end
          end
        end
      end

      -- Store to disk cache if we have items
      if #project_items > 0 then
        store_cached_entry_items(installed_dir, root_dir, project_items, sources)
      end
    end

    -- Store to memory cache
    if utils.is_list(project_items) then
      set_cached_project_items(root_dir, project_items)
    else
      set_cached_project_items(root_dir, {})
    end
  end

  -- Return only project entry items (no need to merge with defaults)
  return project_items or {}
end

return M
