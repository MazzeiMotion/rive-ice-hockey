local PlayerData = require('PlayerData')

-- ===========================================================================
-- SECTION 1: TYPE DEFINITIONS
-- ===========================================================================

type StatusEffect = {
  kind: string,
  timer: number,
  duration: number,
}

type Entity = {
  x: number,
  y: number,
  vx: number,
  vy: number,
  mass: number,
  radius: number,
  friction: number,
  baseRadius: number,
  baseFriction: number,
  effects: { StatusEffect },
  -- For tracking position history to calculate velocity
  prevX: number,
  prevY: number,
}

type Powerup = {
  id: number,
  x: number,
  y: number,
  radius: number,
  kind: string,
  lifespan: number,
  maxLifespan: number,
  instance: Artboard<Data.PowerupVM>?,
}

-- Main Game Type
type IceHockeyV1 = {
  -- Config Inputs
  fieldWidth: Input<number>,
  fieldHeight: Input<number>,
  maxPuckSpeed: Input<number>,
  dragSizeIncrease: Input<number>,

  -- Rules Inputs
  maxPowerups: Input<number>,
  spawnRate: Input<number>,
  maxZoneTime: Input<number>,
  pointsToWin: Input<number>,

  -- Player Inputs
  player1Name: Input<string>,
  player2Name: Input<string>,
  player1Color: Input<Color>,
  player2Color: Input<Color>,

  -- Assets
  playerArtboard: Input<Artboard<Data.PlayerVM>>,
  puckArtboard: Input<Artboard<Data.PuckVM>>,
  powerupArtboard: Input<Artboard<Data.PowerupVM>>,
  player1Goal: Input<Data.GoalVM>,
  player2Goal: Input<Data.GoalVM>,
  score: Input<Data.ScoreVM>,
  middleGraphic: Input<Data.MiddleGraphicVM>, 

  -- Instances
  p1Instance: Artboard<Data.PlayerVM>?,
  p2Instance: Artboard<Data.PlayerVM>?,
  puckInstance: Artboard<Data.PuckVM>?,

  -- Physics State
  puck: Entity,
  p1: Entity,
  p2: Entity,

  -- Game State
  lastTouchedBy: number,
  activeDrags: { [number]: Entity },
  
  -- [NEW] Game Over State
  isGameOver: boolean,
  gameOverTimer: Input<number>,
  gameOverDisplayTime: Input<number>,
  gameResetTimer: number,
  newGameCountdownStarted: boolean,

  -- Player Data
  p1Data: any,
  p2Data: any,

  -- Systems
  powerups: { Powerup },
  spawnTimer: number,
  nextId: number,
  activeG1Height: number,
  activeG2Height: number,
  zoneTimer: number,
  currentZone: number,
  
  -- Countdown tracking
  countdownStarted: boolean,
  
  -- Track if initial positioning has been done
  initialPositionSet: boolean,
}

-- ===========================================================================
-- SECTION 2: MATH & PHYSICS
-- ===========================================================================

local function dist(x1: number, y1: number, x2: number, y2: number): number
  return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

local function clamp(val: number, min: number, max: number): number
  return math.max(min, math.min(max, val))
end

local function resolveCollision(
  self: IceHockeyV1,
  player: Entity,
  puck: Entity,
  playerId: number
)
  local dx = puck.x - player.x
  local dy = puck.y - player.y
  local distance = math.sqrt(dx * dx + dy * dy)
  local minDist = player.radius + puck.radius

  if distance < minDist and distance > 0 then
    self.lastTouchedBy = playerId
    local nx = dx / distance
    local ny = dy / distance
    local overlap = minDist - distance
    puck.x = puck.x + (nx * overlap)
    puck.y = puck.y + (ny * overlap)

    local dvx = puck.vx - player.vx
    local dvy = puck.vy - player.vy
    local dot = (dvx * nx) + (dvy * ny)

    -- Apply impulse if objects are approaching (dot < 0)
    -- OR if player has significant velocity (actively pushing the puck)
    local playerSpeed = math.sqrt(player.vx * player.vx + player.vy * player.vy)
    
    if dot < 0 or playerSpeed > 10 then
      local restitution = 0.8
      -- Use absolute value of dot for impulse calculation when player is pushing
      local effectiveDot = (dot < 0) and dot or -math.abs(dot)
      local impulse = -(1 + restitution) * effectiveDot
      puck.vx = puck.vx + (impulse * nx)
      puck.vy = puck.vy + (impulse * ny)

      local hitPower = 0.5
      puck.vx = puck.vx + (player.vx * hitPower)
      puck.vy = puck.vy + (player.vy * hitPower)

      local currentSpeed = math.sqrt(puck.vx ^ 2 + puck.vy ^ 2)
      if currentSpeed > self.maxPuckSpeed then
        local scale = self.maxPuckSpeed / currentSpeed
        puck.vx = puck.vx * scale
        puck.vy = puck.vy * scale
      end
      
      -- Fire triggerCollision on the player's artboard instance
      local playerInstance = (playerId == 1) and self.p1Instance or self.p2Instance
      if playerInstance and playerInstance.data then
        local triggerCollision = (playerInstance.data :: any).triggerCollision
        if triggerCollision then
          triggerCollision:fire()
        end
      end
    else
      -- Debug: only print when impulse is NOT applied
      print("NO IMPULSE P" .. playerId .. " playerVx=" .. math.floor(player.vx) .. " playerVy=" .. math.floor(player.vy) .. " dot=" .. math.floor(dot) .. " speed=" .. math.floor(playerSpeed))
    end
  end
end

-- Helper for standard goal reset (mid-game)
-- blipColor is the color of the player's side where the puck will spawn
local function resetPuck(self: IceHockeyV1, blipColor: number?)
  self.puck.x = self.fieldWidth / 2
  self.puck.y = self.fieldHeight / 2
  self.lastTouchedBy = 0
  self.zoneTimer = 0
  self.currentZone = 0
  local dir = (math.random() > 0.5) and 1 or -1
  self.puck.vx = 300 * dir
  self.puck.vy = (math.random() * 200) - 100
  
  -- Trigger blip with the destination player's color
  if blipColor and self.puckInstance and self.puckInstance.data then
    if self.puckInstance.data.blipColor then
      self.puckInstance.data.blipColor.value = blipColor
    end
    if self.puckInstance.data.blipTrigger then
      self.puckInstance.data.blipTrigger:fire()
    end
  end
end

-- [NEW] Helper for Full Game Reset (after Game Over)
local function fullReset(self: IceHockeyV1)
  print("STARTING NEW GAME")
  self.p1Data.score = 0
  self.p2Data.score = 0
  self.activeG1Height = 30
  self.activeG2Height = 30
  self.isGameOver = false
  self.newGameCountdownStarted = false
  
  -- Reset Scoreboard UI
  if self.score then
    if self.score.player1Score then self.score.player1Score.value = 0 end
    if self.score.player2Score then self.score.player2Score.value = 0 end
  end
  
  -- Reset puck without blip (new game start)
  resetPuck(self, nil)
end

-- ===========================================================================
-- SECTION 3: STATUS EFFECTS & POWERUPS
-- ===========================================================================

local function addStatusEffect(entity: Entity, kind: string, duration: number)
  for _, fx in ipairs(entity.effects) do
    if fx.kind == kind then
      fx.timer = duration
      return
    end
  end
  table.insert(
    entity.effects,
    { kind = kind, timer = duration, duration = duration }
  )
end

-- Returns the powerup size multiplier for the entity
local function manageStatusEffects(entity: Entity, seconds: number): number
  entity.friction = entity.baseFriction
  local powerupMultiplier = 1.0
  for i = #entity.effects, 1, -1 do
    local fx = entity.effects[i]
    if fx.kind == 'giantPaddle' then
      powerupMultiplier = 1.5
    elseif fx.kind == 'tinyPaddle' then
      powerupMultiplier = 0.7
    end
    fx.timer = fx.timer - seconds
    if fx.timer <= 0 then
      table.remove(entity.effects, i)
    end
  end
  return powerupMultiplier
end

local function applyPowerup(
  self: IceHockeyV1,
  kind: string,
  recipientId: number
)
  local recipientName = (recipientId == 1) and self.p1Data.name
    or self.p2Data.name
  print('Applying Powerup: ' .. kind .. ' to ' .. recipientName)

  if kind == 'smallerGoal' then
    if recipientId == 1 then
      self.activeG1Height = clamp(self.activeG1Height - 5, 5, 90)
    else
      self.activeG2Height = clamp(self.activeG2Height - 5, 5, 90)
    end
  elseif kind == 'biggerGoal' then
    if recipientId == 1 then
      self.activeG2Height = clamp(self.activeG2Height + 5, 5, 90)
    else
      self.activeG1Height = clamp(self.activeG1Height + 5, 5, 90)
    end
  elseif kind == 'giantPaddle' then
    local target = (recipientId == 1) and self.p1 or self.p2
    addStatusEffect(target, 'giantPaddle', 8.0)
  elseif kind == 'tinyPaddle' then
    local target = (recipientId == 1) and self.p2 or self.p1
    addStatusEffect(target, 'tinyPaddle', 8.0)
  end
end

local function spawnPowerup(self: IceHockeyV1)
  if #self.powerups >= self.maxPowerups then
    return
  end
  local padding = 50
  local fW, fH = self.fieldWidth, self.fieldHeight
  local px = math.random(padding, fW - padding)
  local py = math.random(padding, fH - padding)
  local kinds = { 'smallerGoal', 'biggerGoal', 'giantPaddle', 'tinyPaddle' }
  local kind = kinds[math.random(1, #kinds)]

  local inst = nil
  if self.powerupArtboard then
    inst = self.powerupArtboard:instance()
  end
  if inst and inst.data then
    if inst.data.sizeX then
      inst.data.sizeX.value = 60
    end
    if inst.data.sizeY then
      inst.data.sizeY.value = 60
    end
    if inst.data.lifecycle then
      inst.data.lifecycle.value = 100
    end
    if inst.data.kind then
      inst.data.kind.value = kind
    end
    -- Rotate powerup to face the player on that side of the field
    -- Left side (P1's zone) = 90 degrees, Right side (P2's zone) = -90 degrees
    local powerupRotation = (inst.data :: any).powerupRotation
    if powerupRotation then
      local mid = fW / 2
      powerupRotation.value = (px < mid) and 90 or -90
    end
  end

  table.insert(self.powerups, {
    id = self.nextId,
    x = px,
    y = py,
    radius = 30,
    kind = kind,
    lifespan = 10.0,
    maxLifespan = 10.0,
    instance = inst,
  })
  self.nextId = self.nextId + 1
end

local function updatePowerups(self: IceHockeyV1, seconds: number)
  self.spawnTimer = self.spawnTimer + seconds
  if self.spawnTimer >= self.spawnRate then
    self.spawnTimer = 0
    if math.random() > 0.5 then
      spawnPowerup(self)
    end
  end

  for i = #self.powerups, 1, -1 do
    local p = self.powerups[i]
    p.lifespan = p.lifespan - seconds
    if p.lifespan <= 0 then
      table.remove(self.powerups, i)
    else
      if p.instance then
        p.instance:advance(seconds)
        if p.instance.data and p.instance.data.lifecycle then
          p.instance.data.lifecycle.value = (p.lifespan / p.maxLifespan) * 100
        end
      end
      if
        dist(p.x, p.y, self.puck.x, self.puck.y) < (p.radius + self.puck.radius)
      then
        if self.lastTouchedBy ~= 0 then
          applyPowerup(self, p.kind, self.lastTouchedBy)
          table.remove(self.powerups, i)
        end
      end
    end
  end
end

-- ===========================================================================
-- SECTION 4: ARTBOARD MANAGEMENT
-- ===========================================================================

local function createMainArtboards(self: IceHockeyV1)
  -- Player 1
  if self.playerArtboard and not self.p1Instance then
    local inst = self.playerArtboard:instance()
    if inst then
      self.p1Instance = inst
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.p1.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.p1.baseRadius * 2
        end
        if inst.data.color then
          inst.data.color.value = self.p1Data.color
        end
      end
    end
  end
  -- Player 2
  if self.playerArtboard and not self.p2Instance then
    local inst = self.playerArtboard:instance()
    if inst then
      self.p2Instance = inst
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.p2.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.p2.baseRadius * 2
        end
        if inst.data.color then
          inst.data.color.value = self.p2Data.color
        end
      end
    end
  end
  -- Puck
  if self.puckArtboard and not self.puckInstance then
    local inst = self.puckArtboard:instance()
    if inst then
      self.puckInstance = inst
      if inst.data then
        if inst.data.sizeX then
          inst.data.sizeX.value = self.puck.baseRadius * 2
        end
        if inst.data.sizeY then
          inst.data.sizeY.value = self.puck.baseRadius * 2
        end
        -- Trigger blip when puck first spawns with white color
        if inst.data.blipColor then
          inst.data.blipColor.value = 0xFFFFFFFF -- White
        end
        if inst.data.blipTrigger then
          inst.data.blipTrigger:fire()
        end
      end
    end
  end
end

-- ===========================================================================
-- SECTION 5: INTERACTION & LIFECYCLE (MULTI-TOUCH)
-- ===========================================================================

function pointerDown(self: IceHockeyV1, event: PointerEvent)
  -- Prevent interaction during Game Over sequence
  if
    dist(event.position.x, event.position.y, self.p1.x, self.p1.y)
    < self.p1.radius * 2.0
  then
    self.activeDrags[event.id] = self.p1
  elseif
    dist(event.position.x, event.position.y, self.p2.x, self.p2.y)
    < self.p2.radius * 2.0
  then
    self.activeDrags[event.id] = self.p2
  end
  
  -- Count active drags
  local count = 0
  for _ in pairs(self.activeDrags) do count = count + 1 end
  print("pointerDown id=" .. event.id .. " activeDrags=" .. count)
end

function pointerMove(self: IceHockeyV1, event: PointerEvent)
  local entity = self.activeDrags[event.id]
  if entity then
    -- Just update position, velocity will be calculated in advance()
    entity.x = event.position.x
    entity.y = event.position.y
  end
end

function pointerUp(self: IceHockeyV1, event: PointerEvent)
  self.activeDrags[event.id] = nil
  
  -- Count active drags
  local count = 0
  for _ in pairs(self.activeDrags) do count = count + 1 end
  print("pointerUp id=" .. event.id .. " activeDrags=" .. count)
end

function init(self: IceHockeyV1): boolean
  local fW, fH = self.fieldWidth, self.fieldHeight

  self.puck = {
    x = fW / 2,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 1,
    radius = 15,
    baseRadius = 15,
    friction = 0.99,
    baseFriction = 0.99,
    effects = {},
    prevX = fW / 2,
    prevY = fH / 2,
  }
  -- Players spawn at 20% from their respective edges, centered vertically
  local p1SpawnX = fW * 0.2
  local p2SpawnX = fW * 0.8
  self.p1 = {
    x = p1SpawnX,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 10,
    radius = 30,
    baseRadius = 40,
    friction = 0.92,
    baseFriction = 0.92,
    effects = {},
    prevX = p1SpawnX,
    prevY = fH / 2,
  }
  self.p2 = {
    x = p2SpawnX,
    y = fH / 2,
    vx = 0,
    vy = 0,
    mass = 10,
    radius = 30,
    baseRadius = 40,
    friction = 0.92,
    baseFriction = 0.92,
    effects = {},
    prevX = p2SpawnX,
    prevY = fH / 2,
  }

  self.lastTouchedBy = 0
  self.activeDrags = {} 
  self.powerups = {}
  self.spawnTimer = 0
  self.nextId = 1
  self.activeG1Height = 30
  self.activeG2Height = 30
  self.zoneTimer = 0
  self.currentZone = 0
  self.countdownStarted = false
  self.initialPositionSet = false
  
  -- [CHANGED] State for Game Over logic
  self.isGameOver = false
  self.gameResetTimer = 0 -- New internal counter
  self.newGameCountdownStarted = false

  -- Init Player Data (use input colors, with defaults if not set)
  local p1ColorValue = self.player1Color or 0xFFFF0F5C
  local p2ColorValue = self.player2Color or 0xFF3B6AFA
  self.p1Data = PlayerData.new(self.player1Name, p1ColorValue)
  self.p2Data = PlayerData.new(self.player2Name, p2ColorValue)

  -- Initialize Scoreboard
  if self.score then
    if self.score.player1Name then self.score.player1Name.value = self.p1Data.name end
    if self.score.player2Name then self.score.player2Name.value = self.p2Data.name end
    if self.score.player1Color then self.score.player1Color.value = self.p1Data.color end
    if self.score.player2Color then self.score.player2Color.value = self.p2Data.color end
    if self.score.player1Score then self.score.player1Score.value = 0 end
    if self.score.player2Score then self.score.player2Score.value = 0 end
  end

  createMainArtboards(self)
  resetPuck(self)
  return true
end

-- Helper to check if an entity is currently being dragged
local function isEntityDragging(self: IceHockeyV1, entity: Entity): boolean
  for _, e in pairs(self.activeDrags) do
    if e == entity then return true end
  end
  return false
end

function advance(self: IceHockeyV1, seconds: number): boolean
  createMainArtboards(self)

  -- [CHANGED] Game Over Sequence Handler
  if self.isGameOver then
    -- Countdown logic using internal timer
    local prevTimer = self.gameResetTimer
    self.gameResetTimer = self.gameResetTimer - seconds
    
    -- When display time ends: fire playGameOver again to dismiss, reset rotation, start countdown
    if not self.newGameCountdownStarted and self.gameResetTimer <= 0 then
      print("Starting new game countdown. Previous timer was: " .. prevTimer)
      self.newGameCountdownStarted = true
      
      -- Fire playGameOver second time (to disappear)
      if self.score and self.score.playGameOver then
        self.score.playGameOver:fire()
      end
      
      -- Reset scoreRotation back to 0
      if self.score then
        local scoreRotation = (self.score :: any).scoreRotation
        if scoreRotation then
          scoreRotation.value = 0
        end
      end
      
      -- Fire triggerCountdown on middleGraphic for new game countdown
      local middleGraphic = (self :: any).middleGraphic
      if middleGraphic then
        local triggerCountdown = middleGraphic.triggerCountdown
        if triggerCountdown then
          triggerCountdown:fire()
        end
      end
      
      -- Now set timer to the actual countdown time (gameOverTimer)
      if self.gameOverTimer then
        self.gameResetTimer = self.gameOverTimer
      else
        self.gameResetTimer = 3.0 -- Fallback if input is missing
      end
    end
    
    -- Update timeoutCountdown on middleGraphic (only after countdown started)
    if self.newGameCountdownStarted then
      local currentTimer = math.ceil(self.gameResetTimer)
      
      if currentTimer > 0 then
        local middleGraphic = (self :: any).middleGraphic
        if middleGraphic then
          local timeoutCountdown = middleGraphic.timeoutCountdown
          if timeoutCountdown then
            timeoutCountdown.value = currentTimer
          end
        end
      end
      
      if self.gameResetTimer <= 0 then
        -- Fire triggerCountdown again to dismiss
        local middleGraphic = (self :: any).middleGraphic
        if middleGraphic then
          local triggerCountdown = middleGraphic.triggerCountdown
          if triggerCountdown then
            triggerCountdown:fire()
          end
        end
        
        fullReset(self)
      end
    end
    
    -- Continue with player physics during game over (but skip puck/scoring logic)
  end

  -- ==================== NORMAL GAMEPLAY LOOP ====================

  local fW, fH = self.fieldWidth, self.fieldHeight

  -- 1. APPLY EFFECTS
  local p1PowerupMultiplier = manageStatusEffects(self.p1, seconds)
  local p2PowerupMultiplier = manageStatusEffects(self.p2, seconds)

  -- Sync Visuals & UPDATE DRAGGING STATE (including size increase when dragging)
  local p1Dragging = isEntityDragging(self, self.p1)
  local p2Dragging = isEntityDragging(self, self.p2)
  
  -- Apply drag size multiplier on top of powerup multiplier
  local dragMultiplier = 1 + (self.dragSizeIncrease / 100)
  local p1DragMultiplier = p1Dragging and dragMultiplier or 1.0
  local p2DragMultiplier = p2Dragging and dragMultiplier or 1.0
  
  -- Combine powerup and drag multipliers for final radius
  self.p1.radius = self.p1.baseRadius * p1PowerupMultiplier * p1DragMultiplier
  self.p2.radius = self.p2.baseRadius * p2PowerupMultiplier * p2DragMultiplier

  if self.p1Instance and self.p1Instance.data then
    self.p1Instance.data.sizeX.value = self.p1.radius * 2
    self.p1Instance.data.sizeY.value = self.p1.radius * 2
    if self.p1Instance.data.isDragging then
      self.p1Instance.data.isDragging.value = p1Dragging
    end
  end

  if self.p2Instance and self.p2Instance.data then
    self.p2Instance.data.sizeX.value = self.p2.radius * 2
    self.p2Instance.data.sizeY.value = self.p2.radius * 2
    if self.p2Instance.data.isDragging then
      self.p2Instance.data.isDragging.value = p2Dragging
    end
  end

  -- 2. PHYSICS
  -- During game over, only process player entities (not puck)
  local entities: { Entity } = { self.p1, self.p2 }
  if not self.isGameOver then
    table.insert(entities, self.puck)
  end
  for _, e in ipairs(entities) do
    if isEntityDragging(self, e) then
      -- For dragged entities, calculate velocity from position change
      if seconds > 0 then
        e.vx = (e.x - e.prevX) / seconds
        e.vy = (e.y - e.prevY) / seconds
      end
    else
      -- For non-dragged entities, apply physics
      e.x = e.x + (e.vx * seconds)
      e.y = e.y + (e.vy * seconds)
      e.vx = e.vx * e.friction
      e.vy = e.vy * e.friction
      if math.abs(e.vx) < 1 then e.vx = 0 end
      if math.abs(e.vy) < 1 then e.vy = 0 end
    end
    -- Update previous position for next frame
    e.prevX = e.x
    e.prevY = e.y
  end

  -- 4. CONSTRAINTS (always apply to players)
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)

  -- Skip puck-related logic during game over
  if self.isGameOver then
    -- 10. ANIMATIONS (players only during game over)
    if self.p1Instance then self.p1Instance:advance(seconds) end
    if self.p2Instance then self.p2Instance:advance(seconds) end
    return true
  end

  -- 3. ZONE
  local mid = fW / 2
  local newZone = (self.puck.x < mid) and 1 or 2
  if newZone ~= self.currentZone then
    -- Fire triggerCountdown to reset if countdown was active
    if self.countdownStarted then
      local middleGraphic = (self :: any).middleGraphic
      if middleGraphic then
        local triggerCountdown = middleGraphic.triggerCountdown
        if triggerCountdown then
          triggerCountdown:fire()
        end
      end
      self.countdownStarted = false
    end
    self.currentZone = newZone
    self.zoneTimer = 0
  else
    self.zoneTimer = self.zoneTimer + seconds
    
    -- Countdown logic: trigger when 3 seconds remaining
    local timeRemaining = self.maxZoneTime - self.zoneTimer
    if timeRemaining <= 3 and timeRemaining > 0 then
      local countdownNumber = math.ceil(timeRemaining)
      
      -- Fire triggerCountdown when we first enter the 3-second window
      if not self.countdownStarted then
        self.countdownStarted = true
        local middleGraphic = (self :: any).middleGraphic
        if middleGraphic then
          local triggerCountdown = middleGraphic.triggerCountdown
          if triggerCountdown then
            triggerCountdown:fire()
          end
        end
        
        -- Rotate scoreboard to face the player being counted down
        -- P1 (zone 1) = face P1 = 90 degrees
        -- P2 (zone 2) = face P2 = -90 degrees
        if self.score then
          local scoreRotation = (self.score :: any).scoreRotation
          if scoreRotation then
            scoreRotation.value = (self.currentZone == 1) and 90 or -90
          end
        end
      end
      
      -- Update the countdown number
      local middleGraphic = (self :: any).middleGraphic
      if middleGraphic then
        local timeoutCountdown = middleGraphic.timeoutCountdown
        if timeoutCountdown then
          timeoutCountdown.value = countdownNumber
        end
      end
    elseif self.countdownStarted and timeRemaining <= 0 then
      -- Fire triggerCountdown again to reset when countdown finishes
      local middleGraphic = (self :: any).middleGraphic
      if middleGraphic then
        local triggerCountdown = middleGraphic.triggerCountdown
        if triggerCountdown then
          triggerCountdown:fire()
        end
      end
      self.countdownStarted = false
    end
    
    if self.zoneTimer > self.maxZoneTime then
      local zOwner = (self.currentZone == 1) and self.p1Data.name or self.p2Data.name
      local zOwnerColor = (self.currentZone == 1) and self.p1Data.color or self.p2Data.color
      -- Destination player is the opposite of the current zone owner
      local destinationColor = (self.currentZone == 1) and self.p2Data.color or self.p1Data.color
      print('TIME LIMIT: ' .. zOwner .. '\'s Zone!')
      
      -- Set the timed-out player's color on the scoreboard
      if self.score and self.score.mainColor then
        self.score.mainColor.value = zOwnerColor
      end
      
      -- Rotate scoreboard to face the player who got timed out
      -- P1 (zone 1) timed out = face P1 = 90 degrees
      -- P2 (zone 2) timed out = face P2 = -90 degrees
      local scoreRotation = (self.score :: any).scoreRotation
      if scoreRotation then
        scoreRotation.value = (self.currentZone == 1) and 90 or -90
      end
      
      -- Fire the playTimeout trigger in the scoreboard view model
      if self.score and self.score.playTimeout then
        self.score.playTimeout:fire()
      end
      
      -- Move the puck to the other player's side
      if self.currentZone == 1 then
        -- Puck was in Player 1's zone (left), move to Player 2's zone (right)
        self.puck.x = mid + (fW / 4)
      else
        -- Puck was in Player 2's zone (right), move to Player 1's zone (left)
        self.puck.x = fW / 4
      end
      self.puck.y = fH / 2
      self.puck.vx = 0
      self.puck.vy = 0
      self.lastTouchedBy = 0
      
      -- Trigger blip with the destination player's color
      if self.puckInstance and self.puckInstance.data then
        if self.puckInstance.data.blipColor then
          self.puckInstance.data.blipColor.value = destinationColor
        end
        if self.puckInstance.data.blipTrigger then
          self.puckInstance.data.blipTrigger:fire()
        end
      end
      
      self.zoneTimer = 0
      self.currentZone = (self.currentZone == 1) and 2 or 1
      self.countdownStarted = false
    end
  end

  -- 5. GOAL SYNC
  if self.player1Goal and self.player1Goal.height then
    self.player1Goal.height.value = self.activeG1Height
  end
  if self.player2Goal and self.player2Goal.height then
    self.player2Goal.height.value = self.activeG2Height
  end

  -- 6. WALLS
  if self.puck.y < self.puck.radius then
    self.puck.y = self.puck.radius
    self.puck.vy = math.abs(self.puck.vy)
  elseif self.puck.y > fH - self.puck.radius then
    self.puck.y = fH - self.puck.radius
    self.puck.vy = -math.abs(self.puck.vy)
  end

  local p1G = fH * (self.activeG1Height / 100)
  local p2G = fH * (self.activeG2Height / 100)

  if self.puck.x < self.puck.radius then
    if not (self.puck.y > (fH / 2 - p1G / 2) and self.puck.y < (fH / 2 + p1G / 2)) then
      self.puck.x = self.puck.radius
      self.puck.vx = math.abs(self.puck.vx) * 0.8
    end
  end
  if self.puck.x > fW - self.puck.radius then
    if not (self.puck.y > (fH / 2 - p2G / 2) and self.puck.y < (fH / 2 + p2G / 2)) then
      self.puck.x = fW - self.puck.radius
      self.puck.vx = -math.abs(self.puck.vx) * 0.8
    end
  end

  -- 7. COLLISIONS
  resolveCollision(self, self.p1, self.puck, 1)
  resolveCollision(self, self.p2, self.puck, 2)

  -- 8. POWERUPS
  updatePowerups(self, seconds)

  -- 9. SCORING
  local function handleScore(scorerData: any, isP1Scoring: boolean)
    scorerData.score = scorerData.score + 1
    
    -- Update Scoreboard
    if self.score then
      if isP1Scoring then
        if self.score.player1Score then self.score.player1Score.value = scorerData.score end
      else
        if self.score.player2Score then self.score.player2Score.value = scorerData.score end
      end
      if self.score.mainColor then self.score.mainColor.value = scorerData.color end
      
      -- Rotate scoreboard to face the player who scored
      -- P1 scored = face P1 = 90 degrees
      -- P2 scored = face P2 = -90 degrees
      local scoreRotation = (self.score :: any).scoreRotation
      if scoreRotation then
        scoreRotation.value = isP1Scoring and 90 or -90
      end
    end

    -- Check Win Condition
    if scorerData.score >= self.pointsToWin then
      print('GAME OVER! ' .. scorerData.name .. ' Wins!')
      
      if self.score then
        -- Set the winning player's color
        if self.score.mainColor then
          self.score.mainColor.value = scorerData.color
        end
        
        -- Set the main player text to show winner
        local mainPlayer = (self.score :: any).mainPlayer
        if mainPlayer then
          mainPlayer.value = scorerData.name .. "\nWins!"
        end
        
        -- Rotate scoreboard to face the winner
        -- P1 won = face P1 = 90 degrees
        -- P2 won = face P2 = -90 degrees
        local scoreRotation = (self.score :: any).scoreRotation
        if scoreRotation then
          scoreRotation.value = isP1Scoring and 90 or -90
        end
        
        -- Fire playGameOver (first time - to show game over)
        if self.score.playGameOver then
          self.score.playGameOver:fire()
        end
      end
      
      self.isGameOver = true
      self.newGameCountdownStarted = false
      
      -- Set timer to display time (time before countdown starts)
      local displayTime = self.gameOverDisplayTime or 3.0
      if displayTime < 1.0 then
        displayTime = 3.0 -- Ensure minimum display time
      end
      self.gameResetTimer = displayTime
      print("Game Over! Display time: " .. displayTime)
      
      -- Stop puck
      self.puck.vx = 0
      self.puck.vy = 0
      self.puck.x = fW/2 
      self.puck.y = fH/2
    else
      -- Normal Goal
      local msg = isP1Scoring and 'GOAL! ' or 'GOAL! '
      print(msg .. scorerData.name .. ' (' .. self.p1Data.score .. '-' .. self.p2Data.score .. ')')
      
      if self.score and self.score.playGoal then
        self.score.playGoal:fire()
      end
      
      -- Reset puck with blip color of the scoring player (puck spawns with their color)
      resetPuck(self, scorerData.color)
    end
  end

  if self.puck.x < -30 then
    handleScore(self.p2Data, false) -- P2 Scores
  elseif self.puck.x > fW + 30 then
    handleScore(self.p1Data, true) -- P1 Scores
  end

  -- 10. ANIMATIONS
  if self.p1Instance then self.p1Instance:advance(seconds) end
  if self.p2Instance then self.p2Instance:advance(seconds) end
  if self.puckInstance then self.puckInstance:advance(seconds) end

  return true
end

function update(self: IceHockeyV1)
  local fW, fH = self.fieldWidth, self.fieldHeight
  
  -- Set initial positions based on actual field dimensions (runs once)
  if not self.initialPositionSet then
    self.initialPositionSet = true
    
    -- Players spawn at 20% from their respective edges, centered vertically
    local p1SpawnX = fW * 0.2
    local p2SpawnX = fW * 0.8
    
    self.p1.x = p1SpawnX
    self.p1.y = fH / 2
    self.p1.prevX = p1SpawnX
    self.p1.prevY = fH / 2
    
    self.p2.x = p2SpawnX
    self.p2.y = fH / 2
    self.p2.prevX = p2SpawnX
    self.p2.prevY = fH / 2
    
    -- Puck at center
    self.puck.x = fW / 2
    self.puck.y = fH / 2
    self.puck.prevX = fW / 2
    self.puck.prevY = fH / 2
  end
  
  self.p1.x = clamp(self.p1.x, self.p1.radius, (fW / 2) - self.p1.radius)
  self.p1.y = clamp(self.p1.y, self.p1.radius, fH - self.p1.radius)
  self.p2.x = clamp(self.p2.x, (fW / 2) + self.p2.radius, fW - self.p2.radius)
  self.p2.y = clamp(self.p2.y, self.p2.radius, fH - self.p2.radius)
  self.puck.x = clamp(self.puck.x, self.puck.radius, fW - self.puck.radius)
  self.puck.y = clamp(self.puck.y, self.puck.radius, fH - self.puck.radius)

  -- Sync Input Names
  self.p1Data.name = self.player1Name
  self.p2Data.name = self.player2Name

  -- Sync Input Colors (convert to signed int for Rive)
  if self.player1Color then
    self.p1Data.color = PlayerData.toColor(self.player1Color)
  end
  if self.player2Color then
    self.p2Data.color = PlayerData.toColor(self.player2Color)
  end

  -- Sync Scoreboard Names and Colors
  if self.score then
    if self.score.player1Name then self.score.player1Name.value = self.player1Name end
    if self.score.player2Name then self.score.player2Name.value = self.player2Name end
    if self.score.player1Color then self.score.player1Color.value = self.p1Data.color end
    if self.score.player2Color then self.score.player2Color.value = self.p2Data.color end
  end

  -- Sync Player Artboard Colors
  if self.p1Instance and self.p1Instance.data and self.p1Instance.data.color then
    self.p1Instance.data.color.value = self.p1Data.color
  end
  if self.p2Instance and self.p2Instance.data and self.p2Instance.data.color then
    self.p2Instance.data.color.value = self.p2Data.color
  end
end

function draw(self: IceHockeyV1, renderer: Renderer)
  local function drawEnt(inst: Artboard<any>?, e: Entity)
    if inst then
      renderer:save()
      -- Use the entity radius for centering (already includes drag size increase)
      renderer:transform(Mat2D.withTranslation(e.x - e.radius, e.y - e.radius))
      inst:draw(renderer)
      renderer:restore()
    end
  end

  for _, p in ipairs(self.powerups) do
    if p.instance then
      renderer:save()
      renderer:transform(Mat2D.withTranslation(p.x - p.radius, p.y - p.radius))
      p.instance:draw(renderer)
      renderer:restore()
    end
  end

  drawEnt(self.p1Instance, self.p1)
  drawEnt(self.p2Instance, self.p2)
  
  -- Hide puck during game over sequence
  if not self.isGameOver then
    drawEnt(self.puckInstance, self.puck)
  end
end

return function(): Node<IceHockeyV1>
  return {
    init = init,
    advance = advance,
    update = update,
    draw = draw,
    pointerDown = pointerDown,
    pointerMove = pointerMove,
    pointerUp = pointerUp,

    fieldWidth = 500,
    fieldHeight = 300,
    maxPuckSpeed = 1000,
    dragSizeIncrease = 20,
    maxPowerups = 5,
    spawnRate = 3.0,
    maxZoneTime = 7.0,
    pointsToWin = 5,
    player1Name = 'Player 1',
    player2Name = 'Player 2',
    player1Color = 0xFFFF0F5C,
    player2Color = 0xFF3B6AFA,

    playerArtboard = late(),
    puckArtboard = late(),
    powerupArtboard = late(),
    player1Goal = late(),
    player2Goal = late(),
    score = late(),
    middleGraphic = late(),

    p1Instance = nil,
    p2Instance = nil,
    puckInstance = nil,
    
    puck = {
      x = 0, y = 0, vx = 0, vy = 0, radius = 0, mass = 0, friction = 0, baseRadius = 0, baseFriction = 0, effects = {}, prevX = 0, prevY = 0,
    },
    p1 = {
      x = 0, y = 0, vx = 0, vy = 0, radius = 0, mass = 0, friction = 0, baseRadius = 0, baseFriction = 0, effects = {}, prevX = 0, prevY = 0,
    },
    p2 = {
      x = 0, y = 0, vx = 0, vy = 0, radius = 0, mass = 0, friction = 0, baseRadius = 0, baseFriction = 0, effects = {}, prevX = 0, prevY = 0,
    },

    lastTouchedBy = 0,
    activeDrags = {},
    powerups = {},
    spawnTimer = 0,
    nextId = 1,
    activeG1Height = 30,
    activeG2Height = 30,
    zoneTimer = 0,
    currentZone = 0,
    countdownStarted = false,
    initialPositionSet = false,
    
    isGameOver = false,
    gameOverTimer = 3,
    gameOverDisplayTime = 3,
    gameResetTimer = 0,
    newGameCountdownStarted = false,

    p1Data = { name = 'P1', color = 0, score = 0 },
    p2Data = { name = 'P2', color = 0, score = 0 },
  }
end