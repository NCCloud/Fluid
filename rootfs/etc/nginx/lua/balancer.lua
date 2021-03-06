local ngx_balancer = require("ngx.balancer")
local ssl = require("ngx.ssl")
local json = require("cjson")
local configuration = require("configuration")
local lrucache = require("resty.lrucache")
local resty_lock = require("resty.lock")

local static_configs = ngx.shared.static_configs

local lru_cache_config_sync_interval = static_configs:get("lru_cache_config_sync_interval")
if lru_cache_config_sync_interval == nil then
    return error("No lru_cache_config_sync_interval parameter specified")
end
local lru_cache_size = static_configs:get("lru_cache_size")
if lru_cache_size == nil then
    return error("No lru_cache_size parameter specified")
end
local lru_cache_state_timeout = static_configs:get("lru_cache_state_timeout")
if lru_cache_state_timeout == nil then
    return error("No lru_cache_state_timeout parameter specified")
end

-- measured in seconds
-- for an Nginx worker to pick up the new list of configs
-- it will take <the delay until controller POSTed the backend object to the Nginx endpoint> + CONFIG_SYNC_INTERVAL
local CONFIG_SYNC_INTERVAL = lru_cache_config_sync_interval

local LRUCACHE_SIZE = lru_cache_size
local STATE_TIMEOUT = lru_cache_state_timeout

local ROUND_ROBIN_LOCK_KEY = "round_robin"
local CHASH_LOCK_KEY = "chash"

local round_robin_state = ngx.shared.round_robin_state
local chash_state = ngx.shared.chash_state

local _M = {}

local round_robin_lock = resty_lock:new("round_robin_locks", {timeout = 0, exptime = 0.1})
local chash_lock = resty_lock:new("chash_locks", {timeout = 0, exptime = 0.1})

local config_check_code_cache, err = lrucache.new(1)
if not config_check_code_cache then
    return error("failed to create the cache for config_check_code: " .. (err or "unknown"))
end

local servers, servers_err = lrucache.new(LRUCACHE_SIZE)
if not servers then
    return error("failed to create the cache for servers: " .. (servers_err or "unknown"))
end

local backends, backends_err = lrucache.new(LRUCACHE_SIZE)
if not backends then
    return error("failed to create the cache for backends: " .. (backends_err or "unknown"))
end

local chashs, chashs_err = lrucache.new(LRUCACHE_SIZE)
if not chashs then
    return error("failed to create the cache for chashs: " .. (chashs_err or "unknown"))
end

local function sync_config()
    local config_check_code = configuration.get_config_check_code()
    if config_check_code_cache ~= config_check_code then
        local config_data = configuration.get_config_data()
        if not config_data then
            return
        end

        local ok, new_config = pcall(json.decode, config_data)
        if not ok then
            ngx.log(ngx.ERR, "could not parse config data: " .. tostring(new_config))
            return
        end

        local n_servers, n_servers_err = lrucache.new(LRUCACHE_SIZE)
        if not servers then
            return error("failed to create the temporary cache for servers: " .. (n_servers_err or "unknown"))
        end
        local new_servers = new_config.servers
        for _, new_server in pairs(new_servers) do
            ngx.log(ngx.INFO, "server syncronization completed for: " .. new_server.hostname)
            n_servers:set(new_server.hostname, new_server)
        end
        servers = n_servers

        local n_backends, n_backends_err = lrucache.new(LRUCACHE_SIZE)
        if not backends then
            return error("failed to create the temporary cache for backends: " .. (n_backends_err or "unknown"))
        end
        local new_backends = new_config.backends
        for _, new_backend in pairs(new_backends) do
            ngx.log(ngx.INFO, "backend syncronization completed for: " .. new_backend.name)
            n_backends:set(new_backend.name, new_backend)
        end
        backends = n_backends

        ngx.log(ngx.INFO, "Flushing Chash table")
        chash_state:flush_all()

        config_check_code_cache = config_check_code
    end
end

local function load_ctx()
    local http_host = ngx.var.host
    ngx.log(ngx.INFO, "Virtualhost requested: [" .. http_host .. "]")
    local request_uri = ngx.var.request_uri
    if http_host ~= nil then
        if ngx.ctx.server == nil then
            ngx.ctx.server = servers:get(http_host)
            if (ngx.ctx.server == nil) then
                ngx.log(ngx.WARN, "Unable to get virtualhost name [" .. http_host
                        .. "] from ctx cache -> fallback to [_]")
                ngx.ctx.server = servers:get("_")
                if (ngx.ctx.server == nil) then
                    ngx.log(ngx.ERR, "Unable to get virtualhost name from ctx cache")
                    ngx.status = 503
                    ngx.exit(ngx.status)
                end
            end
        end
    end
    if request_uri ~= nil then
        ngx.var.location_path = request_uri
        if ngx.ctx.location == nil then
            local hit_length = 0
            for k, v in pairs(ngx.ctx.server.locations) do
                local path = v.path
                ngx.log(ngx.INFO, "Checking request: " ..    tostring(request_uri) .. " against path: "
                        .. tostring(path))
                local path_length = string.len(v.path)
                if string.sub(request_uri, 1, path_length) == path then
                    if path_length > hit_length then
                        hit_length = path_length
                        ngx.ctx.location = ngx.ctx.server.locations[k]
                        ngx.log(ngx.INFO, "Path MATCH: " .. tostring(path) .. " for backend:"
                                .. tostring(ngx.ctx.location.backend))
                    end
                end
            end
            if (ngx.ctx.location == nil) then
                ngx.status = 404
                ngx.exit(ngx.status)
            end
        end
    end
end

function _M.init_worker()
    _, err = ngx.timer.every(CONFIG_SYNC_INTERVAL, sync_config)
    if err then
        ngx.log(ngx.ERR, "error when setting up timer.every for sync_config: " .. tostring(err))
    end
end

function _M.rewrite()
    load_ctx()

    local scheme = ngx.var.scheme
    local redirect_to_https = ngx.var.redirect_to_https
    if scheme == 'http' then
        ngx.log(ngx.INFO, "SSL Redirect configs: forceSSLRedirect=" ..
                tostring(ngx.ctx.location.rewrite.forceSSLRedirect))
        ngx.log(ngx.INFO, "SSL Redirect configs: sslCertificateReal=" .. tostring(ngx.ctx.server.sslCertificateReal))
        ngx.log(ngx.INFO, "SSL Redirect configs: sslRedirect=" .. tostring(ngx.ctx.location.rewrite.sslRedirect))
        if ngx.ctx.location.rewrite.forceSSLRedirect or
        (ngx.ctx.server.sslCertificateReal ~= "" and ngx.ctx.location.rewrite.sslRedirect) then
            if redirect_to_https == "1" then
                ngx.log(ngx.INFO, "SSL Redirect(" .. ngx.var.http_host .. "): " .. ngx.var.request_uri)
                return ngx.redirect("https://" .. ngx.var.http_host .. ngx.var.request_uri, 301)
            end
        end
    end
end

function _M.ssl()
    local http_host = ssl.server_name()
    if http_host ~= nil then
        ngx.log(ngx.INFO, "SSL server name: ".. http_host )
        local server = servers:get(http_host)
        if (server == nil) then
            server = servers:get("_")
            if (server == nil) then
                ngx.log(ngx.ERR, "Unable to get SSL virtualhost name from ctx cache")
                ngx.status = 503
                ngx.exit(ngx.status)
            end
        end

        if server.sslCertificateReal ~= "" then
            local ok, server_err = ssl.clear_certs()
            if not ok then
                ngx.log(ngx.ERR, "SSL ["..http_host.."]: failed to clear fallback certificates: ", server_err)
                return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
            end
            local cert_key_data = server.sslCertificateReal
            if cert_key_data == nil then
                ngx.log(ngx.ERR, "SSL certificate not found in memory")
                return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
            end
            local der_cert_chain, der_cert_chain_err = ssl.cert_pem_to_der(cert_key_data)
            if not der_cert_chain then
                ngx.log(ngx.ERR, "failed to convert certificate chain ", "from PEM to DER: ", der_cert_chain_err)
                return ngx.exit(ngx.ERROR)
            end
            local set_der_cert_ok, set_der_cert_err = ssl.set_der_cert(der_cert_chain)
            if not set_der_cert_ok then
                ngx.log(ngx.ERR, "failed to set DER cert: ", set_der_cert_err)
                return ngx.exit(ngx.ERROR)
            end
            local der_pkey, priv_key_pem_to_der_err = ssl.priv_key_pem_to_der(cert_key_data)
            if not der_pkey then
                ngx.log(ngx.ERR, "failed to convert private key ", "from PEM to DER: ", priv_key_pem_to_der_err)
                return ngx.exit(ngx.ERROR)
            end
            local set_der_priv_key_ok, set_der_priv_key_err = ssl.set_der_priv_key(der_pkey)
            if not set_der_priv_key_ok then
                ngx.log(ngx.ERR, "failed to set DER private key: ", set_der_priv_key_err)
                return ngx.exit(ngx.ERROR)
            end
        end
    end
end

function _M.balance(lb_alg)
    ngx.log(ngx.INFO, "Load balancing algorithm: " ..    tostring(lb_alg))

    load_ctx()

    local backend_name = ngx.ctx.location.backend
    ngx.var.proxy_upstream_name = backend_name
    ngx.log(ngx.INFO, "Context Backend name:" ..    tostring(backend_name))

    local backend = backends:get(backend_name)

    local host
    local port

    if (backend ~= nil) then
        if lb_alg == "rr" then
            round_robin_lock:lock(backend_name .. ROUND_ROBIN_LOCK_KEY)
            local last_index = round_robin_state:get(backend_name)
            local index, endpoint = next(backend.endpoints, last_index)
            if not index then
                index = 1
                endpoint = backend.endpoints[index]
            end
            round_robin_state:set(backend_name, index, STATE_TIMEOUT)
            round_robin_lock:unlock(backend_name .. ROUND_ROBIN_LOCK_KEY)

            host = endpoint.address
            port = endpoint.port
        elseif lb_alg == "chash" then
            local remote_addr = ngx.var.remote_addr
            local pointer_id = remote_addr .. ":" .. ngx.ctx.server.hostname .. ":" .. ngx.ctx.location.path
            ngx.log(ngx.INFO, "CHASH Balancer pointer: " .. pointer_id)
            chash_lock:lock(pointer_id .. CHASH_LOCK_KEY)

            local state, status = ngx_balancer.get_last_failure()
            if state ~= nil then
                ngx.log(ngx.INFO, "PEER FAILURE:" .. ngx.ctx.server.hostname .. " -> " .. state .. " (" .. status ..
                        ") retrying")
                chash_state:delete(pointer_id)
            end

            local ep_index = chash_state:get(pointer_id)
            local endpoint
            if ep_index == nil then
                ngx.log(ngx.INFO, "Balancer pointer NOT cached, creating new cached endpoint")
                local free_endpoint_id = math.random(#backend.endpoints)
                endpoint = backend.endpoints[free_endpoint_id]
                chash_state:set(pointer_id, free_endpoint_id, STATE_TIMEOUT)
            else
                ngx.log(ngx.INFO, "Balancer pointer cached, with id: " .. tostring(ep_index))
                endpoint = backend.endpoints[ep_index]
                if endpoint == nil then
                    ngx.log(ngx.INFO, "Balancer pointer cached id: " .. tostring(ep_index)
                            .. " INVALID, regenerating cache id")
                    local free_endpoint_id = math.random(#backend.endpoints)
                    endpoint = backend.endpoints[free_endpoint_id]
                else
                    chash_state:set(pointer_id, ep_index, STATE_TIMEOUT)
                end
            end

            chash_lock:unlock(pointer_id .. CHASH_LOCK_KEY)

            host = endpoint.address
            port = endpoint.port
        else
            ngx.log(ngx.ERR, "Load balancing algorithm unknown: " .. tostring(lb_alg))
            ngx.status = 503
            ngx.exit(ngx.status)
        end

        ngx_balancer.set_more_tries(1)
        local ok, err_peer = ngx_balancer.set_current_peer(host, port)
        if ok then
            ngx.log(ngx.INFO, "current peer is set to " .. host .. ":" .. port)
        else
            ngx.log(ngx.ERR, "error while setting current upstream peer to: " .. tostring(err_peer))
            ngx.exit(505)
        end
    end
end

return _M
