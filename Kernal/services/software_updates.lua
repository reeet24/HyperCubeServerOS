local software_updates = {}

local CHUNK_SIZE = 24000
software_updates.VERSION = "0.3.5"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function reply(rednet_api, sender, protocol, response_type, ok, result)
    rednet_api.send(sender, {
        type = response_type,
        ok = ok == true,
        result = ok and result or nil,
        error = ok and nil or result,
        time = now(),
    }, protocol)
end

local function update_metadata(hypercube)
    if hypercube.installer and hypercube.installer.update_metadata_for_device then
        return hypercube.installer:update_metadata_for_device("TPhone")
    end
    if hypercube.installer and hypercube.installer.update_metadata then
        return hypercube.installer:update_metadata()
    end
    return false, "InstallerMetadataUnavailable"
end

local function update_metadata_for_request(hypercube, message)
    local device = tostring(message and message.device or "TPhone")
    if hypercube.installer and hypercube.installer.update_metadata_for_device then
        return hypercube.installer:update_metadata_for_device(device)
    end
    return update_metadata(hypercube)
end

local function build_package_for_request(hypercube, message)
    local device = tostring(message and message.device or "TPhone")
    if hypercube.installer and hypercube.installer.build_update_package_for_device then
        return hypercube.installer:build_update_package_for_device(device)
    end
    if hypercube.installer and hypercube.installer.build_update_package then
        return hypercube.installer:build_update_package()
    end
    return false, "InstallerUnavailable"
end

function software_updates.install(hypercube)
    if not hypercube.network then
        return false, "NetworkUnavailable"
    end
    if not hypercube.installer then
        return false, "InstallerUnavailable"
    end
    if hypercube.update_handler_registered then
        return true
    end

    hypercube.network:register_handler("software_updates", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 7) ~= "update." then
            return false
        end

        local version = hypercube.installer_service and hypercube.installer_service.VERSION
            or (hypercube.installer and hypercube.installer.VERSION)
            or software_updates.VERSION
            or "0.0.0"
        if message.type == "update.status" then
            local current = tostring(message.version or "")
            local metadata_ok, metadata = update_metadata_for_request(hypercube, message)
            reply(rednet, sender, network.protocol, "update.status.result", true, {
                os = "HyperCube",
                device = metadata_ok and metadata.device or tostring(message.device or "TPhone"),
                version = version,
                rom_checksum = metadata_ok and metadata.rom_checksum or nil,
                checksum_available = metadata_ok == true,
                checksum_error = metadata_ok and nil or metadata,
                update_available = current ~= version,
            })
        elseif message.type == "update.download" then
            local ok, result = build_package_for_request(hypercube, message)
            if ok then
                local rom_data = result.rom_data or ""
                local device = result.device or tostring(message.device or "TPhone")
                result.rom_data = nil
                result.chunk_size = CHUNK_SIZE
                result.size = #rom_data
                result.chunks = math.ceil(#rom_data / CHUNK_SIZE)
                hypercube.update_cache = {
                    device = device,
                    package = result,
                    rom_data = rom_data,
                    built_at = now(),
                }
            end
            reply(rednet, sender, network.protocol, "update.download.result", ok, result)
        elseif message.type == "update.chunk" then
            local requested_device = tostring(message.device or "TPhone")
            local cache = hypercube.update_cache
            if not cache or tostring(cache.device or "TPhone") ~= requested_device then
                local ok, result = build_package_for_request(hypercube, message)
                if ok then
                    local rom_data = result.rom_data or ""
                    local device = result.device or requested_device
                    result.rom_data = nil
                    result.chunk_size = CHUNK_SIZE
                    result.size = #rom_data
                    result.chunks = math.ceil(#rom_data / CHUNK_SIZE)
                    cache = {
                        device = device,
                        package = result,
                        rom_data = rom_data,
                        built_at = now(),
                    }
                    hypercube.update_cache = cache
                end
            end
            if not cache then
                reply(rednet, sender, network.protocol, "update.chunk.result", false, "PackageUnavailable")
            else
                local index = math.max(1, tonumber(message.index) or 1)
                local start = ((index - 1) * CHUNK_SIZE) + 1
                local data = cache.rom_data:sub(start, start + CHUNK_SIZE - 1)
                reply(rednet, sender, network.protocol, "update.chunk.result", data ~= "", {
                    index = index,
                    data = data,
                    chunks = cache.package.chunks,
                })
            end
        else
            reply(rednet, sender, network.protocol, "update.error", false, "UnknownUpdateRequest")
        end

        if hypercube.logger then
            hypercube.logger.debug("software update " .. tostring(message.type) .. " sender=" .. tostring(sender), hypercube.root_context)
        end
        return true
    end)

    hypercube.update_handler_registered = true
    if hypercube.logger then
        hypercube.logger.info("software update HyperNet API registered", hypercube.root_context)
    end
    return true
end

function software_updates.start(hypercube)
    local ok, err = software_updates.install(hypercube)
    if not ok then
        return false, err
    end
    while true do
        coroutine.yield("tick")
    end
end

return software_updates
