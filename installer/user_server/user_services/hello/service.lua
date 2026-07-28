local api = ServiceAPI

api.state.started_at = api.state.started_at or (os.epoch and os.epoch("utc") or os.clock())
api.state.ticks = api.state.ticks or 0
api.log.info("started")

while true do
    api.state.ticks = (api.state.ticks or 0) + 1
    coroutine.yield("tick")
end
