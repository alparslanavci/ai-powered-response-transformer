local body_transformer = require "kong.plugins.ai-powered-response-transformer.body_transformer"
local header_transformer = require "kong.plugins.ai-powered-response-transformer.header_transformer"

local transform_headers = header_transformer.transform_headers
local transform_json_body = body_transformer.transform_json_body


local is_body_transform_set = header_transformer.is_body_transform_set
local is_json_body = header_transformer.is_json_body
local kong = kong


local ResponseTransformerHandler = {
  PRIORITY = 1000,
  VERSION = "0.1",
}

function ResponseTransformerHandler:response(conf)
  transform_headers(conf, kong.response.get_headers())

  if not is_body_transform_set(conf)
    or not is_json_body(kong.response.get_header("Content-Type"))
  then
    return
  end

  local body = assert(kong.service.response.get_body())
  local json_body, err = transform_json_body(conf, body)
  if err then
    kong.log.warn("body transform failed: " .. err)
    return
  end

  return kong.response.exit(kong.service.response.get_status(), json_body)
end

return ResponseTransformerHandler
