local EaStamp = { PRIORITY = 900, VERSION = "0.1.2" }

function EaStamp:access(conf)
  kong.service.request.set_header(conf.header_name, conf.header_value)   -- visible to the upstream
  kong.log.set_serialize_value("ea_policy", conf.header_value)           -- and in the access log
end

function EaStamp:header_filter(conf)
  kong.response.set_header(conf.header_name, conf.header_value)          -- visible to the caller
end

return EaStamp
