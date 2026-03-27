-- Dashboard.client.luau (init.client.luau)
-- Builds a live demo UI showing matchmaking metadata and MemoryStore performance.
-- Receives payloads from DashboardBridge (server) via the MmkStats RemoteEvent.
-- All layout built in code — no Studio-side ScreenGui needed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild("MmkStats", 30)

if not remote then
	warn("[Dashboard] MmkStats RemoteEvent not found — is the server running?")
	return
end

-- ── Palette ───────────────────────────────────────────────────────────────────
local C = {
	bg       = Color3.fromRGB(12, 12, 18),
	panel    = Color3.fromRGB(22, 22, 32),
	border   = Color3.fromRGB(45, 45, 65),
	accent   = Color3.fromRGB(88, 166, 255),
	textPri  = Color3.fromRGB(220, 220, 235),
	textSec  = Color3.fromRGB(120, 120, 145),
	green    = Color3.fromRGB(72, 199, 116),
	yellow   = Color3.fromRGB(255, 200, 60),
	red      = Color3.fromRGB(255, 80, 80),
	matchBg  = Color3.fromRGB(30, 30, 44),
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makeLabel(parent, text, size, color, font, order)
	local l = Instance.new("TextLabel")
	l.Text = text
	l.TextSize = size or 13
	l.TextColor3 = color or C.textPri
	l.Font = font or Enum.Font.Gotham
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = UDim2.new(1, 0, 0, (size or 13) + 4)
	l.LayoutOrder = order or 0
	l.Parent = parent
	return l
end

local function makeDivider(parent, order)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, 1)
	f.BackgroundColor3 = C.border
	f.BorderSizePixel = 0
	f.LayoutOrder = order or 0
	f.Parent = parent
	return f
end

-- Creates a titled panel at a given x offset and width.
-- Returns the frame so callers can add children with LayoutOrder >= 2.
-- panelHeight: fixed pixel height (default 264). Using fixed height so a bottom
-- queue strip can be positioned absolutely without the top panels stretching.
local PANEL_HEIGHT = 264

local function makePanel(parent, title, xOffset, width)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, width, 0, PANEL_HEIGHT)
	frame.Position = UDim2.new(0, xOffset, 0, 32)
	frame.BackgroundColor3 = C.panel
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = frame

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = frame

	makeLabel(frame, title, 11, C.textSec, Enum.Font.GothamBold, 0)
	makeDivider(frame, 1)

	return frame
end

-- ── Root ──────────────────────────────────────────────────────────────────────

local gui = Instance.new("ScreenGui")
gui.Name = "MatchmakingDashboard"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Size = UDim2.new(0, 868, 0, 436)
root.Position = UDim2.new(0.5, 0, 0.5, 0)
root.BackgroundColor3 = C.bg
root.BorderSizePixel = 0
root.Parent = gui

local rootCorner = Instance.new("UICorner")
rootCorner.CornerRadius = UDim.new(0, 8)
rootCorner.Parent = root

-- ── Header ────────────────────────────────────────────────────────────────────

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 28)
header.BackgroundColor3 = C.panel
header.BorderSizePixel = 0
header.Parent = root

local hCorner = Instance.new("UICorner")
hCorner.CornerRadius = UDim.new(0, 8)
hCorner.Parent = header

local headerTitle = Instance.new("TextLabel")
headerTitle.Text = "  ◉  RANKED MATCHMAKING"
headerTitle.Font = Enum.Font.GothamBold
headerTitle.TextSize = 13
headerTitle.TextColor3 = C.accent
headerTitle.BackgroundTransparency = 1
headerTitle.Size = UDim2.new(0.7, 0, 1, 0)
headerTitle.TextXAlignment = Enum.TextXAlignment.Left
headerTitle.Parent = header

local modeBadge = Instance.new("TextLabel")
modeBadge.Text = "CONNECTING..."
modeBadge.Font = Enum.Font.GothamBold
modeBadge.TextSize = 11
modeBadge.TextColor3 = C.textSec
modeBadge.BackgroundTransparency = 1
modeBadge.Size = UDim2.new(0.3, -10, 1, 0)
modeBadge.Position = UDim2.new(0.7, 0, 0, 0)
modeBadge.TextXAlignment = Enum.TextXAlignment.Right
modeBadge.Parent = header

-- ── Server list panel (left, 190px) ──────────────────────────────────────────
-- One compact row per simulated server. Row count matches data.servers length.

local serverPanel = makePanel(root, "SERVERS", 8, 190)

-- Pre-build up to 10 server slot frames (covers any realistic SERVER_COUNT).
local serverSlots = {}
local MAX_SERVER_SLOTS = 10

local serverscrollFrame = Instance.new("ScrollingFrame")
serverscrollFrame.Size = UDim2.new(1, 0, 1, -28)
serverscrollFrame.Position = UDim2.new(0, 0, 0, 26)
serverscrollFrame.BackgroundTransparency = 1
serverscrollFrame.BorderSizePixel = 0
serverscrollFrame.ScrollBarThickness = 3
serverscrollFrame.ScrollBarImageColor3 = C.border
serverscrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
serverscrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
serverscrollFrame.Parent = serverPanel

local serverscrollList = Instance.new("UIListLayout")
serverscrollList.SortOrder = Enum.SortOrder.LayoutOrder
serverscrollList.Padding = UDim.new(0, 4)
serverscrollList.Parent = serverscrollFrame

for i = 1, MAX_SERVER_SLOTS do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = C.matchBg
	row.BorderSizePixel = 0
	row.LayoutOrder = i + 1
	row.Visible = false

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 4)
	rc.Parent = row

	local rp = Instance.new("UIPadding")
	rp.PaddingLeft = UDim.new(0, 8)
	rp.PaddingTop = UDim.new(0, 5)
	rp.Parent = row

	local rl = Instance.new("UIListLayout")
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 1)
	rl.Parent = row

	local function sLabel(size, color, order)
		local t = Instance.new("TextLabel")
		t.TextSize = size
		t.TextColor3 = color
		t.Font = Enum.Font.GothamBold
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -8, 0, size + 3)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.LayoutOrder = order
		t.Parent = row
		return t
	end

	serverSlots[i] = {
		frame  = row,
		title  = sLabel(11, C.accent,   1),
		stats  = sLabel(10, C.textPri,  2),
		spread = sLabel(10, C.textSec,  3),
	}
	row.Parent = serverscrollFrame
end

-- ── Performance panel (middle, 208px) ────────────────────────────────────────

local perfPanel = makePanel(root, "MEMORYSTORE OPS", 206, 208)

-- Budget % in large text — colour changes green/yellow/red
local budgetLabel = Instance.new("TextLabel")
budgetLabel.Text = "Budget: —"
budgetLabel.Font = Enum.Font.GothamBold
budgetLabel.TextSize = 17
budgetLabel.TextColor3 = C.green
budgetLabel.BackgroundTransparency = 1
budgetLabel.Size = UDim2.new(1, 0, 0, 24)
budgetLabel.TextXAlignment = Enum.TextXAlignment.Left
budgetLabel.LayoutOrder = 2
budgetLabel.Parent = perfPanel

makeDivider(perfPanel, 3)

local pRows = {}
local function pRow(key, order)
	local r = makeLabel(perfPanel, key .. ": —", 12, C.textPri, Enum.Font.Gotham, order)
	pRows[key] = r
end

pRow("Units total",    4)
pRow("Units/match",    5)
pRow("SetAsync",       6)
pRow("GetRangeAsync",  7)
pRow("UpdateAsync",    8)
pRow("RemoveAsync",    9)

-- ── Bracket pools panel ───────────────────────────────────────────────────────

local bracketPanel = makePanel(root, "BRACKET POOLS", 422, 188)

-- One row per bracket size (1v1, 2v2, 3v3). Pre-built; hidden until data arrives.
local bracketRows = {} -- [size] → { frame, label }
local BRACKET_SIZES = { 1, 2, 3 }

for _, size in BRACKET_SIZES do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 52)
	row.BackgroundColor3 = C.matchBg
	row.BorderSizePixel = 0
	row.LayoutOrder = size + 1
	row.Visible = false

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 4)
	rc.Parent = row

	local rp = Instance.new("UIPadding")
	rp.PaddingLeft = UDim.new(0, 8)
	rp.PaddingTop = UDim.new(0, 6)
	rp.Parent = row

	local rl = Instance.new("UIListLayout")
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 2)
	rl.Parent = row

	local function bLabel(textSize, color, order)
		local t = Instance.new("TextLabel")
		t.TextSize = textSize
		t.TextColor3 = color
		t.Font = Enum.Font.GothamBold
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -8, 0, textSize + 3)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.LayoutOrder = order
		t.Parent = row
		return t
	end

	bracketRows[size] = {
		frame       = row,
		title       = bLabel(12, C.accent,   1),
		queue       = bLabel(11, C.textPri,  2),
		matches     = bLabel(11, C.textSec,  3),
	}
	row.Parent = bracketPanel
end

-- ── Match log panel (right, 244px) ───────────────────────────────────────────

local logPanel = makePanel(root, "RECENT MATCHES", 618, 242)

-- Scrolling frame inside the log panel to handle overflow
local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size = UDim2.new(1, 0, 1, -28)
scrollFrame.Position = UDim2.new(0, 0, 0, 26)
scrollFrame.BackgroundTransparency = 1
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 3
scrollFrame.ScrollBarImageColor3 = C.border
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.Parent = logPanel

local scrollList = Instance.new("UIListLayout")
scrollList.SortOrder = Enum.SortOrder.LayoutOrder
scrollList.Padding = UDim.new(0, 4)
scrollList.Parent = scrollFrame

-- Dynamic match history — one Instance per match, never recycled.
-- seenMatchKeys deduplicates across repeated server payloads.
local seenMatchKeys  = {}
local nextMatchOrder = 0

local function makeMatchKey(m)
	local firstId = (m.teamA and m.teamA[1]) and m.teamA[1].userId or 0
	return string.format("%d_%s_%d", m.timestamp or 0, m.matchType or "", firstId)
end

-- ── Queue snapshot panel (bottom strip, full width) ──────────────────────────
-- Shows up to 20 groups currently waiting in the shared queue.
-- Positioned below the top panels: 32 (header) + 264 (panels) + 8 (gap) = 304
-- Height: 436 - 304 - 8 = 124px

local QUEUE_PANEL_Y = 32 + PANEL_HEIGHT + 8

local queueStripBg = Instance.new("Frame")
queueStripBg.Size = UDim2.new(1, -16, 0, 436 - QUEUE_PANEL_Y - 8)
queueStripBg.Position = UDim2.new(0, 8, 0, QUEUE_PANEL_Y)
queueStripBg.BackgroundColor3 = C.panel
queueStripBg.BorderSizePixel = 0
queueStripBg.Parent = root

local qsCorner = Instance.new("UICorner")
qsCorner.CornerRadius = UDim.new(0, 6)
qsCorner.Parent = queueStripBg

local qsTitle = Instance.new("TextLabel")
qsTitle.Text = "WAITING QUEUE"
qsTitle.Font = Enum.Font.GothamBold
qsTitle.TextSize = 11
qsTitle.TextColor3 = C.textSec
qsTitle.BackgroundTransparency = 1
qsTitle.Size = UDim2.new(1, -16, 0, 16)
qsTitle.Position = UDim2.new(0, 10, 0, 6)
qsTitle.TextXAlignment = Enum.TextXAlignment.Left
qsTitle.Parent = queueStripBg

local qsDivider = Instance.new("Frame")
qsDivider.Size = UDim2.new(1, -20, 0, 1)
qsDivider.Position = UDim2.new(0, 10, 0, 24)
qsDivider.BackgroundColor3 = C.border
qsDivider.BorderSizePixel = 0
qsDivider.Parent = queueStripBg

-- Scrollable list of queue entries
local queueScroll = Instance.new("ScrollingFrame")
queueScroll.Size = UDim2.new(1, -20, 1, -32)
queueScroll.Position = UDim2.new(0, 10, 0, 28)
queueScroll.BackgroundTransparency = 1
queueScroll.BorderSizePixel = 0
queueScroll.ScrollBarThickness = 3
queueScroll.ScrollBarImageColor3 = C.border
queueScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
queueScroll.AutomaticCanvasSize = Enum.AutomaticSize.X -- horizontal scroll for many entries
queueScroll.ScrollingDirection = Enum.ScrollingDirection.X
queueScroll.Parent = queueStripBg

local queueRowList = Instance.new("UIListLayout")
queueRowList.FillDirection = Enum.FillDirection.Horizontal
queueRowList.SortOrder = Enum.SortOrder.LayoutOrder
queueRowList.Padding = UDim.new(0, 6)
queueRowList.Parent = queueScroll

-- Pre-build 20 queue entry chips (one per waiting group)
local queueChips = {}
local MAX_QUEUE_CHIPS = 20

for i = 1, MAX_QUEUE_CHIPS do
	local chip = Instance.new("Frame")
	chip.Size = UDim2.new(0, 110, 1, 0)
	chip.BackgroundColor3 = C.matchBg
	chip.BorderSizePixel = 0
	chip.LayoutOrder = i
	chip.Visible = false

	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 4)
	cc.Parent = chip

	local cp = Instance.new("UIPadding")
	cp.PaddingLeft = UDim.new(0, 7)
	cp.PaddingTop = UDim.new(0, 5)
	cp.Parent = chip

	local cl = Instance.new("UIListLayout")
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.Padding = UDim.new(0, 1)
	cl.Parent = chip

	local function chipLabel(size, color, order)
		local t = Instance.new("TextLabel")
		t.TextSize = size
		t.TextColor3 = color
		t.Font = Enum.Font.Gotham
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -7, 0, size + 3)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.LayoutOrder = order
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Parent = chip
		return t
	end

	queueChips[i] = {
		frame  = chip,
		name   = chipLabel(10, C.textPri, 1), -- "Alice+Bob"
		info   = chipLabel(9,  C.textSec, 2), -- "[2v2] 1200 MMR"
		wait   = chipLabel(9,  C.accent,  3), -- "12s waiting"
	}
	chip.Parent = queueScroll
end

-- ── Match entry helpers ────────────────────────────────────────────────────────

local function memberNames(members)
	local names = {}
	for _, m in members do table.insert(names, m.displayName) end
	return table.concat(names, "+")
end

local function memberDetail(members)
	local parts = {}
	for _, m in members do
		table.insert(parts, string.format("%s (%s %d)", m.displayName, m.rank, m.mmr))
	end
	return table.concat(parts, "  +  ")
end

local function avgMmr(members)
	local sum = 0
	for _, m in members do sum += m.mmr end
	return math.round(sum / #members)
end

-- Creates a new frame for one match and prepends it to the scroll list.
-- nextMatchOrder decrements so newer entries always sort above older ones.
local function createMatchEntry(m)
	nextMatchOrder -= 1

	local ef = Instance.new("Frame")
	ef.Size = UDim2.new(1, -4, 0, 0)
	ef.AutomaticSize = Enum.AutomaticSize.Y
	ef.BackgroundColor3 = C.matchBg
	ef.BorderSizePixel = 0
	ef.LayoutOrder = nextMatchOrder
	ef.Parent = scrollFrame

	local ec = Instance.new("UICorner")
	ec.CornerRadius = UDim.new(0, 4)
	ec.Parent = ef

	local ep = Instance.new("UIPadding")
	ep.PaddingLeft = UDim.new(0, 8)
	ep.PaddingTop = UDim.new(0, 6)
	ep.PaddingBottom = UDim.new(0, 6)
	ep.PaddingRight = UDim.new(0, 8)
	ep.Parent = ef

	local el = Instance.new("UIListLayout")
	el.SortOrder = Enum.SortOrder.LayoutOrder
	el.Padding = UDim.new(0, 2)
	el.Parent = ef

	local function eLabel(size, color, font, order)
		local t = Instance.new("TextLabel")
		t.TextSize = size
		t.TextColor3 = color
		t.Font = font or Enum.Font.Gotham
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, 0, 0, size + 4)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.LayoutOrder = order
		t.RichText = true
		t.TextWrapped = true
		t.AutomaticSize = Enum.AutomaticSize.Y
		t.Parent = ef
		return t
	end

	local winSide   = m.winner == "A" and "A" or "B"
	local deltaWin  = m.winner == "A" and m.deltaA or m.deltaB
	local deltaLose = m.winner == "A" and m.deltaB or m.deltaA
	local timeStr   = m.timestamp and os.date("%H:%M:%S", m.timestamp) or "--:--:--"

	local lHeader = eLabel(11, C.accent,  Enum.Font.GothamBold, 1)
	local lA      = eLabel(10, C.textPri, Enum.Font.Gotham,     2)
	local lB      = eLabel(10, C.textPri, Enum.Font.Gotham,     3)
	local lRes    = eLabel(11, C.green,   Enum.Font.GothamBold, 4)
	local lTime   = eLabel(9,  C.textSec, Enum.Font.Gotham,     5)

	lHeader.Text = string.format("[%s]  %s  vs  %s",
		m.matchType or "?v?", memberNames(m.teamA), memberNames(m.teamB))
	lA.Text    = "A: " .. memberDetail(m.teamA)
	lB.Text    = "B: " .. memberDetail(m.teamB)
	lRes.Text  = string.format("▲ Team %s  %+d / %+d  |  avg %d vs %d",
		winSide, deltaWin, deltaLose, avgMmr(m.teamA), avgMmr(m.teamB))
	lTime.Text = timeStr
end

-- ── Update ────────────────────────────────────────────────────────────────────

local function budgetColor(pct)
	if pct < 30 then return C.green
	elseif pct < 70 then return C.yellow
	else return C.red
	end
end

local function onData(data)
	-- Header
	modeBadge.Text = data.mode
	modeBadge.TextColor3 = data.mode == "DEMO" and C.green or C.yellow

	-- Server list panel
	local servers = data.servers or {}
	for i = 1, MAX_SERVER_SLOTS do
		local slot = serverSlots[i]
		local s = servers[i]
		if s then
			slot.frame.Visible = true
			slot.title.Text  = s.serverId
			slot.stats.Text  = string.format("T:%-3d  M:%-3d  Q:%d", s.tickCount, s.totalMatches, s.queueSize)
			slot.spread.Text = string.format("Spread expanded: %d", s.spreadExpandedCount)
		else
			slot.frame.Visible = false
		end
	end

	-- Perf panel
	local pct = data.budgetPct or 0
	budgetLabel.Text = string.format("Budget used: %.1f%%", pct)
	budgetLabel.TextColor3 = budgetColor(pct)

	pRows["Units total"].Text   = string.format("Units total:     %d  (%d matches)", data.totalUnits, data.totalMatches or 0)
	pRows["Units/match"].Text   = string.format("Units/match:     %.1f", data.unitsPerMatch or 0)
	pRows["SetAsync"].Text      = string.format("SetAsync:        %d calls", data.setCalls)
	pRows["GetRangeAsync"].Text = string.format("GetRangeAsync:   %d calls", data.getRangeCalls)
	pRows["UpdateAsync"].Text   = string.format("UpdateAsync:     %d calls", data.updateCalls)
	pRows["RemoveAsync"].Text   = string.format("RemoveAsync:     %d calls", data.removeCalls)

	-- Bracket pools panel
	local bStats = data.bracketStats or {}
	for _, size in BRACKET_SIZES do
		local row = bracketRows[size]
		local b = bStats[size]
		if b then
			row.frame.Visible = true
			row.title.Text   = b.bracket
			row.queue.Text   = string.format("Waiting: %d players", b.queuePlayers)
			row.matches.Text = string.format("This tick: %d  |  Total: %d", b.matchesThisTick, b.totalMatches)
		else
			row.frame.Visible = false
		end
	end

	-- Match log — append-only; only create entries for matches not yet shown
	local matches = data.recentMatches or {}
	local newMatches = {}
	for _, m in matches do
		local key = makeMatchKey(m)
		if not seenMatchKeys[key] then
			seenMatchKeys[key] = true
			table.insert(newMatches, m)
		end
	end
	-- newMatches is newest-first from the server; process oldest-first so the
	-- newest entry ends up with the lowest LayoutOrder (top of scroll list).
	for i = #newMatches, 1, -1 do
		createMatchEntry(newMatches[i])
	end

	-- Queue snapshot — horizontal chip strip showing waiting groups
	local snap = data.queueSnapshot or {}
	for i = 1, MAX_QUEUE_CHIPS do
		local chip = queueChips[i]
		local g = snap[i]
		if g then
			chip.frame.Visible = true
			chip.name.Text = g.label
			chip.info.Text = string.format("[%dv%d] %dp  %d MMR", g.queueType or g.size, g.queueType or g.size, g.size, g.avgMmr)
			chip.wait.Text = string.format("%ds waiting", g.waitSeconds)
		else
			chip.frame.Visible = false
		end
	end
end

remote.OnClientEvent:Connect(onData)
