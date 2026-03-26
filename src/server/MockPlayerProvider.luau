-- MockPlayerProvider.luau
-- Single source of all fake player data.
-- Zero game logic — data only. Every other system is unaware this data is fake.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RankCalculator = require(script.Parent.RankCalculator)

local MockPlayerProvider = {}

-- Display name pool. Loops if more players than names are seeded.
local NAMES = {
	"Archer", "Blaze", "Comet", "Drake", "Echo",
	"Frostbite", "Ghost", "Havoc", "Ironside", "Jade",
	"Kraken", "Lynx", "Maverick", "Nova", "Omega",
	"Phantom", "Quake", "Raven", "Specter", "Titan",
	"Ultra", "Viper", "Wolf", "Xero", "Yield", "Zenith",
	"Abyss", "Bolt", "Cipher", "Dusk",
}

local REGIONS = { "NA", "EU", "ASIA" }

local _pool: { any } = {}
local _nextId = 1

-- Bell-curve MMR distribution centered at Gold (1200 MMR), std dev ~500.
-- This gives a realistic rank spread: mostly Gold/Silver, fewer at extremes.
local function randomMMR(): number
	-- Box-Muller transform approximation
	local u = math.max(math.random(), 1e-10) -- guard against log(0)
	local v = math.random()
	local z = math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v)
	return math.clamp(math.round(1200 + z * 500), 0, 3000)
end

local function makePlayer(mmr: number): any
	local id = _nextId
	_nextId += 1
	return {
		userId = id,
		displayName = NAMES[(id - 1) % #NAMES + 1] .. string.format("_%02d", id),
		mmr = mmr,
		rank = RankCalculator.getRankTier(mmr),
		wins = math.random(0, 300),
		losses = math.random(0, 300),
		region = REGIONS[math.random(1, #REGIONS)],
		queueJoinTime = os.time(),
		isBot = true,
	}
end

-- Seed the internal pool with `count` mock players.
-- Call this before any getNextPlayer() or drainAll() calls.
function MockPlayerProvider.seed(count: number)
	_pool = {}
	_nextId = 1
	for _ = 1, count do
		table.insert(_pool, makePlayer(randomMMR()))
	end
	print(string.format("[MockProvider] Seeded %d players into pool", #_pool))
end

-- Pop one random player from the pool (simulates a player joining the queue).
-- Returns nil when the pool is empty.
function MockPlayerProvider.getNextPlayer(): any?
	if #_pool == 0 then
		return nil
	end
	local idx = math.random(1, #_pool)
	local player = _pool[idx]
	table.remove(_pool, idx)
	player.queueJoinTime = os.time()
	return player
end

-- Remove and return all remaining players at once (bulk queue seed).
function MockPlayerProvider.drainAll(): { any }
	local all = _pool
	_pool = {}
	for _, p in all do
		p.queueJoinTime = os.time()
	end
	return all
end

function MockPlayerProvider.poolSize(): number
	return #_pool
end

return MockPlayerProvider
