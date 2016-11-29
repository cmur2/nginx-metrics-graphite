
local MetricsGraphite = {}
MetricsGraphite.__index = MetricsGraphite

function MetricsGraphite.init(carbon_host, interval, mbase)
  local self = setmetatable({}, MetricsGraphite)
  ngx.log(ngx.INFO, "nginx-metrics-graphite initializing on nginx version " .. ngx.config.nginx_version .. " with ngx_lua version " .. ngx.config.ngx_lua_version)
  self.carbon_host = carbon_host
  self.interval = interval
  self.mbase = mbase

  -- metadata tables for more flexible metric creation
  self.query_status = {
    status_5xx = 500,
    status_4xx = 400,
    status_3xx = 300,
    status_2xx = 200,
    status_1xx = 100
  }
  self.query_method = {
    method_get = "GET",
    method_head = "HEAD",
    method_put = "PUT",
    method_post = "POST",
    method_delete = "DELETE",
    method_options = "OPTIONS",
    method_other = ""
  }
  self.query_http = {
    http_09 = 0.9,
    http_10 = 1.0,
    http_11 = 1.1,
    http_20 = 2.0
  }

  -- initialize/reset counters
  self.stats = ngx.shared.metrics_graphite -- TODO: unclear whether ngx.shared.DICT is thread-safe?
  self.stats:set("main_loop_worker", 0)

  self.stats:set("requests", 0) -- total number
  self.stats:set("upstream_requests", 0) -- requests which used an upstream server
  self.stats:set("gzip_requests", 0) -- responses which used gzip
  self.stats:set("ssl_requests", 0) -- requests which used ssl

  self.stats:set("request_length", 0)
  self.stats:set("bytes_sent", 0)

  self.stats:set("request_time_sum", 0)
  self.stats:set("request_time_num", 0)

  for k,v in pairs(self.query_status) do
    self.stats:set(k, 0)
  end

  for k,v in pairs(self.query_method) do
    self.stats:set(k, 0)
  end

  for k,v in pairs(self.query_http) do
    self.stats:set(k, 0)
  end

  return self
end

function MetricsGraphite:worker()
  -- determine which worker should handle the main loop, relies on thread-safety of ngx.shared.DICT:incr
  if self.stats:incr("main_loop_worker", 1) ~= 1 then
    return
  end

  ngx.log(ngx.INFO, "nginx-metrics-graphite main loop worker PID is " .. ngx.worker.pid())

  local this = self
  local callback

  callback = function (premature)
    -- first create the new timer to keep our intervals as good as possible
    -- (not when called premature since nginx is going to shut down soon)
    if not premature then
      local ok, err = ngx.timer.at(this.interval, callback)
      if not ok then
        ngx.log(ngx.ERR, "nginx-metrics-graphite callback failed to create interval timer: ", err)
        return
      end
    end

    -- then do the work which might incur delays
    local sock, err = ngx.socket.tcp()
    if err then
      ngx.log(ngx.ERR, "nginx-metrics-graphite callback failed to create carbon socket: ", err)
      return
    end

    -- connect to carbon host with submission port via TCP
    local ok, err = sock:connect(this.carbon_host, 2003)
    if not ok then
      ngx.log(ngx.ERR, "nginx-metrics-graphite callback failed to connect carbon socket: ", err)
      return
    end

    local avg_request_time = this.stats:get("request_time_sum") / this.stats:get("request_time_num")
    self.stats:set("request_time_sum", 0)
    self.stats:set("request_time_num", 0)

    -- submit metrics
    sock:send(this.mbase .. ".nginx_metrics.num_requests " .. this.stats:get("requests") .. " " .. ngx.time() .. "\n")
    sock:send(this.mbase .. ".nginx_metrics.acc_request_length " .. this.stats:get("request_length") .. " " .. ngx.time() .. "\n")
    sock:send(this.mbase .. ".nginx_metrics.acc_bytes_sent " .. this.stats:get("bytes_sent") .. " " .. ngx.time() .. "\n")
    sock:send(this.mbase .. ".nginx_metrics.avg_request_time " .. avg_request_time .. " " .. ngx.time() .. "\n")

    for k,v in pairs(self.query_status) do
      sock:send(this.mbase .. ".nginx_metrics.num_" .. k .. " " .. this.stats:get(k) .. " " .. ngx.time() .. "\n")
    end

    for k,v in pairs(self.query_method) do
      sock:send(this.mbase .. ".nginx_metrics.num_" .. k .. " " .. this.stats:get(k) .. " " .. ngx.time() .. "\n")
    end

    for k,v in pairs(self.query_http) do
      sock:send(this.mbase .. ".nginx_metrics.num_" .. k .. " " .. this.stats:get(k) .. " " .. ngx.time() .. "\n")
    end

    sock:close()
  end

  -- start first timer
  local ok, err = ngx.timer.at(this.interval, callback)
  if not ok then
    ngx.log(ngx.ERR, "nginx-metrics-graphite callback failed to create interval timer: ", err)
    return
  end
end

function MetricsGraphite:log()
  -- function by default called on every request,
  -- should be fast and only do important calculations here
  self.stats:incr("requests", 1)
  if ngx.var.upstream_response_time ~= nil then
    self.stats:incr("upstream_requests", 1)
  end
  if ngx.var.gzip_ratio ~= nil then
    self.stats:incr("gzip_requests", 1)
  end
  if ngx.var.ssl_protocol ~= nil then
    self.stats:incr("ssl_requests", 1)
  end

  for k,v in pairs(self.query_status) do
    if ngx.status >= v and ngx.status < v+100 then
      self.stats:incr(k, 1)
      break
    end
  end

  local is_method_other = true
  for k,v in pairs(self.query_method) do
    if ngx.req.get_method() == v then
      self.stats:incr(k, 1)
      is_method_other = false
      break
    end
  end
  if is_method_other then
    self.stats:incr("method_other", 1)
  end

  for k,v in pairs(self.query_http) do
    -- float equaliy
    if math.abs(v - ngx.req.http_version()) < 0.01 then
      self.stats:incr(k, 1)
      break
    end
  end

  local request_length = ngx.var.request_length -- in bytes
  self.stats:incr("request_length", request_length)

  local bytes_sent = ngx.var.bytes_sent -- in bytes
  self.stats:incr("bytes_sent", bytes_sent)

  local request_time = ngx.now() - ngx.req.start_time() -- in seconds
  self.stats:incr("request_time_sum", request_time)
  self.stats:incr("request_time_num", 1)
end

return MetricsGraphite
