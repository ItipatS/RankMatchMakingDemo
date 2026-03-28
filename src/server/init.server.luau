-- init.server.luau
-- Entry point. Runs either the demo test (real MemoryStore) or the stress test (mock).
--   RUN_STRESS_TEST = false → DemoTest:  proves real MemoryStore API works end-to-end
--   RUN_STRESS_TEST = true  → StressTest: proves CAS correctness under multi-server load

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

if Constants.RUN_STRESS_TEST then
	require(script.StressTest).run()
else
	require(script.DemoTest).run()
end