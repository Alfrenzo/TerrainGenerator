--[[
	TerrainGenerator.lua
	--------------------
	Procedurally spawns trees, rocks, terrain pieces, and a border ring
	around the map on server start. A button near the spawn point lets 
    any player trigger a full regeneration at runtime.

	Workspace folder layout created by this script:
	  SpawnedTerrain/
	    SpawnedTrees/   - tree models
	    SpawnedRocks/   - rock models
        SpawnedBorder/  - border models
	    SpawnedGround/  - ground models

	Required assets (must exist under ReplicatedStorage.Models):
	  Trees   – folder of tree models or BaseParts
	  Rocks   – folder of rock models or BaseParts
	  Terrain – folder of terrain-piece models or BaseParts
	  Border  – folder of border-piece models or BaseParts

	Generation passes (in order):
	  1. Border ring   – continuous ring of pieces just inside the map edge
	  2. Terrain ring  – scattered rock/cliff pieces in a mid-map ring zone
	  3. Trees & rocks – density-weighted batches across the playable area

	Passes 2 and 3 yield when generation takes too long, to avoid slowing 
    down the server.
--]]

-- ============================================================
-- Services
-- ============================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- ============================================================
-- Configuration
-- ============================================================

-- World layout
local SPAWN_POSITION    = workspace.SpawnLocation.Position
local SPAWN_SAFE_RADIUS = 70
local MAP_SIZE          = 500

-- Trees & rocks
local BATCH_SPREAD       = 25 -- max offset from batch origin a piece can spawn
local TREE_TO_ROCK_RATIO = 0.6  -- 60% trees, 40% rocks
local TREE_ROCK_INSET    = 10 -- distance from the edge of the map trees/rocks can spawn

-- Terrain pieces
local TERRAIN_INNER      = 0.50  -- inner edge of the ring (raise → ring moves further from spawn)
local TERRAIN_OUTER      = 0.85  -- outer edge of the ring (lower → keeps pieces away from the map edge)
local TERRAIN_MAX_CHANCE = 0.60  -- peak spawn probability at the ring's midpoint

local TERRAIN_BATCH_MIN    = 1
local TERRAIN_BATCH_MAX    = 3
local TERRAIN_BATCH_SPREAD = 30 -- max offset from batch origin a piece can spawn
local TERRAIN_BATCH_MAX_DIST = TERRAIN_BATCH_SPREAD * math.sqrt(2)

-- Pieces further from their batch origin sink deeper into the ground
local TERRAIN_SINK_MIN = 0
local TERRAIN_SINK_MAX = 12

-- Border ring
local BORDER_SPACING           = 15
local BORDER_INSET             = 15
local BORDER_SCALE_MIN         = 90
local BORDER_SCALE_MAX         = 115
local BORDER_ROTATION_VARIANCE = 15
local BORDER_COLOR_A           = Color3.fromRGB(160,  95, 53)
local BORDER_COLOR_B           = Color3.fromRGB(184, 108, 61)

-- Generation
local GRID_SIZE    = 35  -- studs between grid sample points
local YIELD_BUDGET = 1/1000 -- time before a yield is triggered from server delay (lower = smoother, slower)

local TAU = math.pi * 2

-- ============================================================
-- Model pools
-- ============================================================

local Trees         = ReplicatedStorage.Models.Trees:GetChildren()
local Rocks         = ReplicatedStorage.Models.Rocks:GetChildren()
local TerrainPieces = ReplicatedStorage.Models.Terrain:GetChildren()
local BorderPieces  = ReplicatedStorage.Models.Border:GetChildren()

-- ============================================================
-- Output folders
-- ============================================================

local SpawnedItems  = Instance.new("Folder")
SpawnedItems.Name   = "SpawnedTerrain"
SpawnedItems.Parent = workspace

local SpawnedTrees  = Instance.new("Folder")
SpawnedTrees.Name   = "SpawnedTrees"
SpawnedTrees.Parent = SpawnedItems

local SpawnedRocks  = Instance.new("Folder")
SpawnedRocks.Name   = "SpawnedRocks"
SpawnedRocks.Parent = SpawnedItems

local SpawnedBorder  = Instance.new("Folder")
SpawnedBorder.Name   = "SpawnedBorder"
SpawnedBorder.Parent = SpawnedItems

local SpawnedGround  = Instance.new("Folder")
SpawnedGround.Name   = "SpawnedBorder"
SpawnedGround.Parent = SpawnedItems

-- ============================================================
-- Raycast parameters
-- ============================================================

local sharedRayParams = RaycastParams.new()
sharedRayParams.FilterType = Enum.RaycastFilterType.Exclude
sharedRayParams.FilterDescendantsInstances = { SpawnedItems }

local batchRayParams = RaycastParams.new()
batchRayParams.FilterType = Enum.RaycastFilterType.Exclude
batchRayParams.FilterDescendantsInstances = { SpawnedItems }

-- ============================================================
-- Bottom-Y offset cache
-- ============================================================
-- Caches the Y offset from a model's pivot to the lowest point of any BasePart in the model

local bottomYCache = {}

local function buildBottomYCache(pool)
	for _, template in pairs(pool) do
		if not template:IsA("Model") then continue end

		local minY  = math.huge
		local found = false
		for _, part in pairs(template:GetDescendants()) do
			if part:IsA("BasePart") then
				minY  = math.min(minY, part.Position.Y - part.Size.Y * 0.5)
				found = true
			end
		end

		if found then
			bottomYCache[template] = minY - template:GetPivot().Position.Y
		end
	end
end

buildBottomYCache(Trees)
buildBottomYCache(Rocks)
buildBottomYCache(TerrainPieces)
buildBottomYCache(BorderPieces)

-- ============================================================
-- Regeneration button
-- ============================================================

local regenPart       = Instance.new("Part")
regenPart.Name        = "RegenTerrain"
regenPart.Size        = Vector3.new(10, 1, 10)
regenPart.Position    = Vector3.new(SPAWN_POSITION.X, SPAWN_POSITION.Y, SPAWN_POSITION.Z + 15)
regenPart.Anchored    = true
regenPart.BrickColor  = BrickColor.new("Lime green")
regenPart.Material    = Enum.Material.Neon
regenPart.Parent      = workspace

local billboardGui       = Instance.new("BillboardGui")
billboardGui.Size        = UDim2.new(0, 200, 0, 50)
billboardGui.StudsOffset = Vector3.new(0, 3, 0)
billboardGui.AlwaysOnTop = true
billboardGui.Parent      = regenPart

local regenLabel                  = Instance.new("TextLabel")
regenLabel.Size                   = UDim2.new(1, 0, 1, 0)
regenLabel.BackgroundTransparency = 1
regenLabel.Text                   = "🔄 Regenerate"
regenLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
regenLabel.TextScaled             = true
regenLabel.Font                   = Enum.Font.GothamBold
regenLabel.Parent                 = billboardGui

-- ============================================================
-- Util functions
-- ============================================================

--- Returns the world-space Y of the lowest point of a placed model clone
local function getModelBottomY(model, template)
    if template and bottomYCache[template] then
		return model:GetPivot().Position.Y + bottomYCache[template]
	end
	local minY  = math.huge
	local found = false
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			minY  = math.min(minY, part.Position.Y - part.Size.Y * 0.5)
			found = true
		end
	end
	return found and minY or nil
end

local function raycastDown(x, z)
	return workspace:Raycast(
		Vector3.new(x, 200, z),
		Vector3.new(0, -400, 0),
		sharedRayParams
	)
end

-- ============================================================
-- Density functions
-- ============================================================

--- Returns the spawn probability for a terrain-piece batch at a world position
local function getTerrainPieceDensity(x, z)
	local halfMap  = MAP_SIZE * 0.5
	local edgeness = math.max(math.abs(x) / halfMap, math.abs(z) / halfMap)

	if edgeness < TERRAIN_INNER or edgeness > TERRAIN_OUTER then return 0 end

	local t = (edgeness - TERRAIN_INNER) / (TERRAIN_OUTER - TERRAIN_INNER)
	return math.sin(t * math.pi) * TERRAIN_MAX_CHANCE
end

--- Returns the spawn probability for a tree/rock batch at a given distance from spawn
local function getTreeRockDensity(distance)
	if distance < SPAWN_SAFE_RADIUS then return 0 end
	return math.min((distance - SPAWN_SAFE_RADIUS) / 150, 0.7)
end

-- ============================================================
-- Pass 1 – Border ring
-- ============================================================

--- Spawns a continuous ring of border pieces just inside all four map edges.
local function generateBorder()
	if #BorderPieces == 0 then return end

	local half        = MAP_SIZE * 0.5 - BORDER_INSET
	local varianceRad = math.rad(BORDER_ROTATION_VARIANCE)

	local sides = {
		{ axis = "X", fixed = -half, from = -half, to = half, facing = 0             },  -- top
		{ axis = "X", fixed =  half, from = -half, to = half, facing = math.pi       },  -- bottom
		{ axis = "Z", fixed = -half, from = -half, to = half, facing = math.pi * 0.5 },  -- left
		{ axis = "Z", fixed =  half, from = -half, to = half, facing = math.pi * 1.5 },  -- right
	}

	for _, side in pairs(sides) do
		local pieceCount = 0
		local pos        = side.from

		while pos <= side.to do
			local wx = side.axis == "X" and pos or side.fixed
			local wz = side.axis == "Z" and pos or side.fixed

			local rayResult = workspace:Raycast(
				Vector3.new(wx, 500, wz),
				Vector3.new(0, -1000, 0),
				sharedRayParams
			)

			if rayResult then
				local template = BorderPieces[math.random(1, #BorderPieces)]
				local piece    = template:Clone()
				local scale    = math.random(BORDER_SCALE_MIN, BORDER_SCALE_MAX) / 100
				local rotation = side.facing + (math.random() * 2 - 1) * varianceRad

				-- Alternate dirt tint on each consecutive piece for visual variety
				pieceCount       = pieceCount + 1
				local pieceColor = (pieceCount % 2 == 0) and BORDER_COLOR_B or BORDER_COLOR_A
				local dirtPart   = piece:IsA("Model") and piece:FindFirstChild("DirtPart", true)
				                   or (piece.Name == "DirtPart" and piece or nil)
				if dirtPart and dirtPart:IsA("BasePart") then
					dirtPart.Color = pieceColor
				end

				if piece:IsA("Model") then
					piece:ScaleTo(scale)
					piece:PivotTo(CFrame.new(0, 0, 0))
					local bottomY = getModelBottomY(piece, template)
					local baseY   = bottomY and (rayResult.Position.Y - bottomY) or rayResult.Position.Y
					piece:PivotTo(CFrame.new(wx, baseY, wz) * CFrame.Angles(0, rotation, 0))

				elseif piece:IsA("BasePart") then
					piece.Size     = piece.Size * scale
					piece.Anchored = true
					piece.CFrame   = CFrame.new(wx, rayResult.Position.Y + piece.Size.Y * 0.5, wz)
					               * CFrame.Angles(0, rotation, 0)
				end

				piece.Parent = SpawnedBorder
			end

			pos = pos + BORDER_SPACING
		end
	end
end

-- ============================================================
-- Pass 2 – Terrain pieces
-- ============================================================

--- Attempts to place a small cluster of terrain pieces at a world position
local function spawnTerrainPieces(x, z)
	if #TerrainPieces == 0 then return end
	if math.random() > getTerrainPieceDensity(x, z) then return end

	local batchSize = math.random(TERRAIN_BATCH_MIN, TERRAIN_BATCH_MAX)

	for _ = 1, batchSize do
		local offsetX = math.random(-TERRAIN_BATCH_SPREAD, TERRAIN_BATCH_SPREAD)
		local offsetZ = math.random(-TERRAIN_BATCH_SPREAD, TERRAIN_BATCH_SPREAD)

		local rayResult = raycastDown(x + offsetX, z + offsetZ)
		if not rayResult then continue end

		local template = TerrainPieces[math.random(1, #TerrainPieces)]
		local piece    = template:Clone()
		local scaleX   = math.random(100, 400) / 100
		local scaleZ   = math.random(100, 400) / 100
		local rotation = math.random() * TAU

		-- Scale sink depth linearly with distance from origin, plus small noise
		local distNorm = math.sqrt(offsetX ^ 2 + offsetZ ^ 2) / TERRAIN_BATCH_MAX_DIST
		local sink     = TERRAIN_SINK_MIN + (TERRAIN_SINK_MAX - TERRAIN_SINK_MIN) * distNorm + math.random(-10, 10) / 10

		local groundY = rayResult.Position.Y

		if piece:IsA("Model") then
			piece:PivotTo(CFrame.new(0, 0, 0))
			for _, part in pairs(piece:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Size = Vector3.new(part.Size.X * scaleX, part.Size.Y, part.Size.Z * scaleZ)
				end
			end
			local bottomY = getModelBottomY(piece, template)
			local baseY   = bottomY and (groundY - bottomY) or groundY
			piece:PivotTo(CFrame.new(x + offsetX, baseY - sink, z + offsetZ) * CFrame.Angles(0, rotation, 0))
			piece.Parent = SpawnedGround
            
		elseif piece:IsA("BasePart") then
			piece.Size     = Vector3.new(piece.Size.X * scaleX, piece.Size.Y, piece.Size.Z * scaleZ)
			piece.CFrame   = CFrame.new(x + offsetX, groundY - piece.Size.Y * 0.5 - sink, z + offsetZ)
			               * CFrame.Angles(0, rotation, 0)
			piece.Parent = SpawnedGround
		else
			piece:Destroy()
		end
	end
end

-- ============================================================
-- Pass 3 – Trees & rocks
-- ============================================================

--- Attempts to place a mixed batch of trees and rocks at a world position
local function spawnTreeRockBatch(x, z)
	local distance = (Vector3.new(x, 0, z) - Vector3.new(SPAWN_POSITION.X, 0, SPAWN_POSITION.Z)).Magnitude
	if math.random() > getTreeRockDensity(distance) then return end

	local batchSize = math.random(2, 5)

	for _ = 1, batchSize do
		local offset    = Vector3.new(
			math.random(-BATCH_SPREAD, BATCH_SPREAD),
			0,
			math.random(-BATCH_SPREAD, BATCH_SPREAD)
		)

        local halfMap = MAP_SIZE * 0.5 - TREE_ROCK_INSET
        if math.abs(x + offset.X) > halfMap or math.abs(z + offset.Z) > halfMap then continue end

		local rayOrigin = Vector3.new(x, 0, z) + offset + Vector3.new(0, 500, 0)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -1000, 0), batchRayParams)
		if not rayResult then continue end

		local isTree = math.random() < TREE_TO_ROCK_RATIO and #Trees > 0
		local pool   = isTree and Trees or Rocks
		if #pool == 0 then continue end

		local template = pool[math.random(1, #pool)]
		local item     = template:Clone()
		local scale    = isTree and (math.random(80,  120) / 100)
		                         or (math.random(40,  120) / 100)
		local rotation = math.random() * TAU

		if item:IsA("Model") then
			item:ScaleTo(scale)
			item:PivotTo(CFrame.new(0, 0, 0))
			local bottomY = getModelBottomY(item, template)
            if bottomY and bottomYCache[template] then
                -- re-derive using scaled offset
                bottomY = item:GetPivot().Position.Y + bottomYCache[template] * scale
            end
			local baseY   = bottomY and (rayResult.Position.Y - bottomY) or rayResult.Position.Y
			item:PivotTo(CFrame.new(rayResult.Position.X, baseY, rayResult.Position.Z)
			           * CFrame.Angles(0, rotation, 0))

		elseif item:IsA("BasePart") then
			item.Size   = item.Size * scale
			item.CFrame = CFrame.new(rayResult.Position) * CFrame.Angles(0, rotation, 0)
		end

		item.Parent = isTree and SpawnedTrees or SpawnedRocks
	end
end

-- ============================================================
-- Clear & generate
-- ============================================================

--- Destroys all currently spawned terrain and recreates the output sub-folders
local function clearTerrain()
	for _, item in pairs(SpawnedItems:GetChildren()) do
		item:Destroy()
	end

	SpawnedTrees        = Instance.new("Folder")
	SpawnedTrees.Name   = "SpawnedTrees"
	SpawnedTrees.Parent = SpawnedItems

	SpawnedRocks        = Instance.new("Folder")
	SpawnedRocks.Name   = "SpawnedRocks"
	SpawnedRocks.Parent = SpawnedItems

    SpawnedBorder        = Instance.new("Folder")
    SpawnedBorder.Name   = "SpawnedBorder"
    SpawnedBorder.Parent = SpawnedItems

    SpawnedGround        = Instance.new("Folder")
    SpawnedGround.Name   = "SpawnedGround"
    SpawnedGround.Parent = SpawnedItems
end

local function runGridPass(fn)
    local lastYield = os.clock()
    for x = -MAP_SIZE * 0.5, MAP_SIZE * 0.5, GRID_SIZE do
        for z = -MAP_SIZE * 0.5, MAP_SIZE * 0.5, GRID_SIZE do
            fn(x, z)
        end
        if os.clock() - lastYield >= YIELD_BUDGET then
            task.wait()
            lastYield = os.clock()
        end
    end
end

local function generateTerrain()
	generateBorder()
    -- Refresh folders
    batchRayParams.FilterDescendantsInstances = { regenPart, SpawnedTrees, SpawnedRocks }
	runGridPass(spawnTerrainPieces)
    runGridPass(spawnTreeRockBatch)
end

-- ============================================================
-- Regeneration trigger
-- ============================================================

local isRegenerating = false

regenPart.Touched:Connect(function(hit)
	if not Players:GetPlayerFromCharacter(hit.Parent) then return end
	if isRegenerating then return end
	isRegenerating = true

	regenPart.BrickColor = BrickColor.new("Bright yellow")
	regenLabel.Text      = "🔄 Regenerating..."

	clearTerrain()

	task.spawn(function()
		generateTerrain()
		task.wait(2)
		regenPart.BrickColor = BrickColor.new("Lime green")
		regenLabel.Text      = "🔄 Regenerate"
		isRegenerating       = false
	end)
end)

-- ============================================================
-- Initial generation
-- ============================================================

task.spawn(generateTerrain)