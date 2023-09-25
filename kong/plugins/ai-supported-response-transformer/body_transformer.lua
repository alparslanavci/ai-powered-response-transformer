local http = require "resty.http"

local cjson = require("cjson.safe").new()
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode

local kong = kong

local insert = table.insert
local type = type
local sub = string.sub
local gsub = string.gsub
local byte = string.byte
local match = string.match
local tonumber = tonumber
local pcall = pcall


cjson.decode_array_with_array_mt(true)


local noop = function() end


local QUOTE  = byte([["]])


local _M = {}


local function toboolean(value)
  if value == "true" then
    return true

  else
    return false
  end
end


local function cast_value(value, value_type)
  if value_type == "number" then
    return tonumber(value)

  elseif value_type == "boolean" then
    return toboolean(value)

  else
    return value
  end
end


local function json_value(value, json_type)
  local v = cjson_encode(value)
  if v and byte(v, 1) == QUOTE and byte(v, -1) == QUOTE then
    v = gsub(sub(v, 2, -2), [[\"]], [["]]) -- To prevent having double encoded quotes
  end

  v = v and gsub(v, [[\/]], [[/]]) -- To prevent having double encoded slashes

  if json_type then
    v = cast_value(v, json_type)
  end

  return v
end


local function parse_json(body)
  if body then
    local ok, res = pcall(cjson_decode, body)
    if ok then
      return res
    end
  end
end


local function append_value(current_value, value)
  local current_value_type = type(current_value)

  if current_value_type == "string" then
    return { current_value, value }
  end

  if current_value_type == "table" then
    insert(current_value, value)
    return current_value
  end

  return { value }
end

local function iter(config_array)
  if type(config_array) ~= "table" then
    return noop
  end

  return function(config_array, i)
    i = i + 1

    local current_pair = config_array[i]
    if current_pair == nil then -- n + 1
      return nil
    end

    local current_name, current_value = match(current_pair, "^([^:]+):*(.-)$")
    if current_value == "" then
      current_value = nil
    end

    return i, current_name, current_value
  end, config_array, 0
end

local function generate_input(json_body, value)
  return value:gsub("${([^}]+)}", function(param_name)
    return json_body[param_name]
  end)
end

local function get_ai_output(conf, input, max_tokens)
  local api_key = conf.openai_api_key
  if api_key == nil then
    kong.log.err("no openai api key set")
    return
  end

  local httpc = http.new()

  local res, err = httpc:request_uri("https://api.openai.com/v1/chat/completions", {
    method = "POST",
    body = "{\"model\": \"gpt-3.5-turbo\",\"messages\": [{\"role\": \"system\",\"content\": \"Generate direct responses without conversation as JSON using this template: {\\\"response\\\": \\\"\\\"}\"},{\"role\": \"user\",\"content\": \"" .. input .. "\"}],\"max_tokens\": " .. max_tokens .. "}",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    },
  })
  if not res then
    kong.log.err("openai request failed", err)
    return
  end

  local json_body = parse_json(res.body)
  if json_body == nil then
    kong.log.err("json parse failed")
    return
  end

  local response_json = parse_json(json_body.choices[1].message.content)
  if response_json == nil then
    kong.log.err("json parse failed")
    return
  end

  return response_json.response
end


function _M.transform_json_body(conf, json_body)
  -- remove key:value to body
  for _, name in iter(conf.remove.json) do
    json_body[name] = nil
  end

  -- replace key:value to body
  local replace_json_types = conf.replace.json_types
  for i, name, value in iter(conf.replace.json) do
    local v = json_value(value, replace_json_types and replace_json_types[i])

    if json_body[name] and v ~= nil then
      json_body[name] = v
    end
  end

  -- replace_with_ai key:value to body
  for i, name, value in iter(conf.replace_with_ai.json) do
    local input = generate_input(json_body, value)
    local ai_output = get_ai_output(conf, input, conf.replace_with_ai.max_tokens)
    local v = json_value(ai_output, "string")

    if json_body[name] and v ~= nil then
      json_body[name] = v
    end
  end

  -- add new key:value to body
  local add_json_types = conf.add.json_types
  for i, name, value in iter(conf.add.json) do
    local v = json_value(value, add_json_types and add_json_types[i])

    if not json_body[name] and v ~= nil then
      json_body[name] = v
    end
  end

  -- add_with_ai new key:value to body
  for i, name, value in iter(conf.add_with_ai.json) do
    local input = generate_input(json_body, value)
    local ai_output = get_ai_output(conf, input, conf.add_with_ai.max_tokens)
    local v = json_value(ai_output, "string")

    if not json_body[name] and v ~= nil then
      json_body[name] = v
    end
  end

  -- append new key:value or value to existing key
  local append_json_types = conf.append.json_types
  for i, name, value in iter(conf.append.json) do
    local v = json_value(value, append_json_types and append_json_types[i])

    if v ~= nil then
      json_body[name] = append_value(json_body[name], v)
    end
  end

  return cjson_encode(json_body)
end


return _M
