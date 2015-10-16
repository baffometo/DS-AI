

require "behaviours/chaseandattack"
require "behaviours/runaway"
require "behaviours/doaction"

require "behaviours/panic"

require "behaviours/managehunger"
require "behaviours/managehealth"
require "behaviours/findandactivate"
require "behaviours/findresourceonground"
require "behaviours/findresourcetoharvest"
require "behaviours/findtreeorrock"
require "behaviours/findormakelight"
require "behaviours/doscience"
require "behaviours/cookfood"

require "brains/ai_build_helper"
require "brains/ai_combat_helper"

local MIN_SEARCH_DISTANCE = 15
local MAX_SEARCH_DISTANCE = 100
local SEARCH_SIZE_STEP = 10
local RUN_AWAY_SEE_DIST = 5
local RUN_AWAY_STOP_DIST = 10
local CurrentSearchDistance = MIN_SEARCH_DISTANCE

-- What to gather. This is a simple FIFO. Highest priority will be first in the list.
local GATHER_LIST = {}
local function addToGatherList(_name, _prefab, _number)
	-- Group by name only. If we get a request to add something to the table with the same name and prefab type,
	-- ignore it
	for k,v in pairs(GATHER_LIST) do
		if v.prefab == _prefab and v.name == "name" then
			return
		end
	end
	
	-- New request for this thing. Add it. 
	local value = {name = _name, prefab = _prefab, number = _number}
	table.insert(GATHER_LIST,value)
end

-- Decrement from the FIRST prefab that matches this amount regardless of name
local function decrementFromGatherList(_prefab,_number)
	for k,v in pairs(GATHER_LIST) do
		if v.prefab == _prefab then
			v.number = v.number - _number
			if v.number <= 0 then
				GATHER_LIST[k] = nil
			end
			return
		end
	end
end

local function addRecipeToGatherList(thingToBuild, addFullRecipe)
	local recipe = GetRecipe(thingToBuild)
    if recipe then
		local player = GetPlayer()
        for ik, iv in pairs(recipe.ingredients) do
			-- TODO: This will add the entire recipe. Should modify based on current inventory
			if addFullRecipe then
				print("Adding " .. iv.amount .. " " .. iv.type .. " to GATHER_LIST")
				addToGatherList(iv.type,iv.amount)
			else
				-- Subtract what we already have
				-- TODO subtract what we can make as well... (man, this is complicated)
				local hasEnough = false
				local numHas = 0
				hasEnough, numHas = player.components.inventory:Has(iv.type,iv.amount)
				if not hasEnough then
					print("Adding " .. tostring(iv.amount-numHas) .. " " .. iv.type .. " to GATHER_LIST")
					addToGatherList(iv.type,iv.amount-numHas)
				end
			end
		end
    end
end
---------------------------------------------------------------------------------


-- Makes sure we have the right tech level.
-- If we don't have a resource, checks to see if we can craft it/them
-- If we can craft all necessary resources to build something, returns true
-- else, returns false
-- Do not set recursive variable, it will be set on recursive calls
--local itemsNeeded = {}
local function CanIBuildThis(player, thingToBuild, numToBuild, recursive)

	-- Reset the table if it exists
	if player.itemsNeeded and not recursive then
		for k,v in pairs(player.itemsNeeded) do player.itemsNeeded[k]=nil end
		recursive = 0
	elseif player.itemsNeeded == nil then
		player.itemsNeeded = {}
	end
	
	if numToBuild == nil then numToBuild = 1 end
	
	local recipe = GetRecipe(thingToBuild)
	
	-- Not a real thing so we can't possibly build this
	if not recipe then 
		print(thingToBuild .. " is not buildable :(")
		return false 
	end
	
	-- Quick check, do we know how to build this thing?
	if not player.components.builder:KnowsRecipe(thingToBuild) then
		-- Check if we can prototype it 
		print("We don't know how to build " .. thingToBuild)
		local tech_level = player.components.builder.accessible_tech_trees
		if not CanPrototypeRecipe(recipe.level, tech_level) then
			print("...nor can we prototype it")
			return false 
		else
			print("...but we can prototype it!")
		end
	end

	-- For each ingredient, check to see if we have it. If not, see if it's creatable
	for ik,iv in pairs(recipe.ingredients) do
		local hasEnough = false
		local numHas = 0
		local totalAmountNeeded = math.ceil(iv.amount*numToBuild)
		hasEnough, numHas = player.components.inventory:Has(iv.type,totalAmountNeeded)
		
		-- Subtract things already reserved from numHas
		for i,j in pairs(player.itemsNeeded) do
			if j.prefab == iv.type then
				numHas = math.max(0,numHas - 1)
			end
		end
		
		-- If we don't have or don't have enough for this ingredient, see if we can craft some more
		if numHas < totalAmountNeeded then
			local needed = totalAmountNeeded - numHas
			-- Before checking, add the current numHas to the table so the recursive
			-- call doesn't consider them valid.
			-- Make it level 0 as we already have this good.
			if numHas > 0 then
				table.insert(player.itemsNeeded,1,{prefab=iv.type,amount=numHas,level=0})
			end
			-- Recursive check...can we make this ingredient
			local canCraft = CanIBuildThis(player,iv.type,needed,recursive+1)
			if not canCraft then
				print("Need " .. tostring(needed) .. " " .. iv.type .. "s but can't make them")
				return false
			else
				-- We know the recipe to build this and have the goods. Add it to the list
				-- This should get added in the recursive case
				--table.insert(player.itemsNeeded,1,{prefab=iv.type, amount=needed, level=recursive, toMake=thingToBuild})
			end
		else
			-- We already have enough to build this resource. Add these to the list
			print("Adding " .. tostring(totalAmountNeeded) .. " of " .. iv.type .. " at level " .. tostring(recursive) .. " to the itemsNeeded list")
			table.insert(player.itemsNeeded,1,{prefab=iv.type, amount=totalAmountNeeded, level=recursive, toMake=thingToBuild, toMakeNum=numToBuild})
		end
	end
	
	-- We made it here, we can make this thingy
	return true
end

-- Should only be called after the above call to ensure we can build it.
local function BuildThis(player, thingToBuild, pos)
	local recipe = GetRecipe(thingToBuild)
	-- not a real thing
	if not recipe then return end
	
	print("BuildThis called with " .. thingToBuild)
	
	-- This should not be called without checking to see if we can build something
	-- we have to unlock the recipe here. It is usually done with a mouse event when a player
	-- goes to build something....so I assume if we got here, we can actually unlock the recipe
	-- Actually, Do this in the callback so we don't unlock it unless successful
	--if not player.components.builder:KnowsRecipe(thingToBuild) then
	--	print("Unlocking recipe")
	--	player.components.builder:UnlockRecipe(thingToBuild)
	--end
	
	-- Don't run if we're still buffer building something else
	if player.currentBufferedBuild ~= nil then
		print("Not building " .. thingToBuild .. " as we are still building " .. player.currentBufferedBuild)
		return
	end
	
	-- Save this. We'll catch the 'buildfinished' event and if it is this, we'll remove it.
	-- Will also remove it in watchdog
	player.currentBufferedBuild = thingToBuild
	
	-- TODO: Make sure the pos supplied is valid place to build this thing. If not, get a new one.
	--if pos ~= nil then
	--	local maxLoops = 5
	--	while not player.components.builder:CanBuildAtPoint(pos,thingToBuild) and maxLoops > 0 then
	--		local offset,result_angle,deflected = FindWalkableOffset(pos, angle,radius,8,true,false)
	--		maxLoops = maxLoops - 1
	--	end
	--end
	
	-- Called back from the MakeRecipe function...will unlock the recipe if successful
	local onsuccess = function()
		player.components.builder:UnlockRecipe(thingToBuild)
	end
	
	if not player.itemsNeeded or #player.itemsNeeded == 0 then
		print("itemsNeeded is empty!")
	end
	
	for k,v in pairs(player.itemsNeeded) do print(k,v) end
		
	-- TODO: Make sure we have the inventory space! 
	for k,v in pairs(player.itemsNeeded) do
		-- Just go down the list. If level > 0, we need to build it
		if v.level > 0 and v.toMake then
			-- We should be able to build this...
			print("Trying to build " .. v.toMake)
			while v.toMakeNum > 0 do 
				if player.components.builder:CanBuild(v.toMake) then

					local action = BufferedAction(player,nil,ACTIONS.BUILD,nil,pos,v.toMake,nil)
					player:PushBufferedAction(action)
					--player.components.locomotor:PushAction(action)
					--player.components.builder:MakeRecipe(GetRecipe(v.toMake),pos,onsuccess)
					v.toMakeNum = v.toMakeNum - 1
				else
					print("Uhh...we can't make " .. v.toMake .. "!!!")
					player.currentBufferedBuild = nil
					return
				end
			end
		end
	end
	
	--[[
	if player.components.builder:MakeRecipe(GetRecipe(thingToBuild),pos,onsuccess) then
		print("MakeRecipe succeeded")
	else
		print("Something is messed up. MakeRecipe failed!")
		player.currentBufferedBuild = nil
	end
	--]]
	

	if player.components.builder:CanBuild(thingToBuild) then
		print("We have all the ingredients...time to make " .. thingToBuild)

		local action = BufferedAction(player,player,ACTIONS.BUILD,nil,pos,thingToBuild,nil)
		print("Pushing action to build " .. thingToBuild)
		print(action:__tostring())
		--player.components.builder:MakeRecipe(thingToBuild,pos,onsuccess)
		player:PushBufferedAction(action)
	else
		print("Something is messed up. We can't make " .. thingToBuild .. "!!!")
		player.currentBufferedBuild = nil
	end

end


------------------------------------------------------------------------------------------------

local ArtificalBrain = Class(Brain, function(self, inst)
    Brain._ctor(self,inst)
end)

-- Helper functions to be used by behaviour nodes

local IGNORE_LIST = {}
local TRY_AGAIN_DIST = 15
function ArtificalBrain:OnIgnoreList(prefab)
	if not prefab then return false end
	if IGNORE_LIST[prefab] == nil then return false end
	
	if IGNORE_LIST[prefab].always then return true end
		
	-- Loop through the positions and compare with current pos
	for k,v in pairs(IGNORE_LIST[prefab].posTable) do
	   local dsq = self.inst:GetDistanceSqToPoint(v)
	   if dsq then
    	   if dsq <= TRY_AGAIN_DIST*TRY_AGAIN_DIST then
    	       --print("Too close to a point we tried before")
    	       return true   	       
    	   end
       end
	end
	
	print("We can try " .. tostring(prefab) .. " again...")
	return false
	
	-- Some things are only ignored depending on your position
	
end

-- Need to supply more info to this so it can cleanup things.
-- For example...if wilson is stuck and keeps ignoring things
-- in an area, it would be nice to specify the place to ignore
-- from. 
-- Then when looking up if to ignore something, only ignore it if 
-- standing in the same general area as before.
-- Currently, he will just never look at those things again.
-- Could even do a dumb timeout for these...but then he might
-- just go back to that point at sometime in the future and
-- befored to relearn to ingnore them.
function ArtificalBrain:AddToIgnoreList(prefab, fromPos)
	if not prefab then return end
	print("Adding " .. tostring(prefab) .. " to the ignore list")
	--IGNORE_LIST[prefab] = fromPos or 1
	
	if IGNORE_LIST[prefab] == nil then
	   IGNORE_LIST[prefab] = {}
	   IGNORE_LIST[prefab].posTable = {}
	   IGNORE_LIST[prefab].always = false
	end
	
	-- If this is defined, it means we want to ignore ALL types
	-- of this prefab.
	if not fromPos then 
	   IGNORE_LIST[prefab].always = true
	else
	   -- We only want to ignore this specific GUID from this
	   -- specific region
	   table.insert(IGNORE_LIST[prefab].posTable, fromPos)
	end
end

function ArtificalBrain:RemoveFromIgnoreList(prefab)
	if not prefab then return end
	if self:OnIgnoreList(prefab) then
		IGNORE_LIST[prefab] = nil
	end
end

-- For debugging 
function ArtificalBrain:GetIgnoreList()
    return IGNORE_LIST
end

-- Helpful function...just returns a point at a random angle 
-- a distance dist away.
function ArtificalBrain:GetPointNearThing(thing, dist)
	local pos = Vector3(thing.Transform:GetWorldPosition())
	if pos then
		local theta = math.random() * 2 * PI
		local radius = dist
		local offset = FindWalkableOffset(pos, theta, radius, 12, true)
		if offset then
			return pos+offset
		end
	end
end

-- Just copied the function. Other one will go away soon.
function ArtificalBrain:HostileMobNearInst(inst)
	local pos = inst.Transform:GetWorldPosition()
	if pos then
		return FindEntity(inst,RUN_AWAY_SEE_DIST,function(guy) return ShouldRunAway(guy) end) ~= nil
	end
	return false
end

function ArtificalBrain:GetCurrentSearchDistance()
	return CurrentSearchDistance
end

function ArtificalBrain:IncreaseSearchDistance()
	CurrentSearchDistance = math.min(MAX_SEARCH_DISTANCE,CurrentSearchDistance + SEARCH_SIZE_STEP)
		print("IncreaseSearchDistance to: " .. tostring(CurrentSearchDistance))
end

function ArtificalBrain:ResetSearchDistance()
	CurrentSearchDistance = MIN_SEARCH_DISTANCE
end

local function OnPathFinder(self,data)
    print("Pathfinder has failed!")
    if data then
        if data.inst then
            print(data.inst.prefab .. " has failed a pathfinding search")
        end
        if data.target then
            print("Adding " .. data.target.prefab .. " GUID to ignore list")
            self.brain:AddToIgnoreList(data.target.entity:GetGUID(), Vector3(self.Transform:GetWorldPosition()))
        end
    end
    
    if self.components.locomotor.isrunning then
        local rand = math.random()
        if rand > .66 then 
            self.components.talker:Say("I'm too dumb to walk around this...")
        elseif rand > .33 then
            self.components.talker:Say("Stupid water...")
        end
        
        -- NONE OF THIS WORKS! WHY WONT HE STOP MOVING!!!
        
        if self.components.locomotor.bufferedaction then
            print("Calling FAIL")
            self.components.locomotor.bufferedaction:Fail()
        end
        
        self.components.locomotor:SetBufferedAction(nil)
        self:StopUpdatingComponent(self.components.locomotor)
        self.components.locomotor.wantstomoveforward = false
        self.components.locomotor:StopMoving()

        --self.components.locomotor:Stop()
        --self.components.locomotor.dest = nil
        --self.components.locomotor:StopMoving()
    end

    -- This will kickstart the brain.
    self:AddTag("IsStuck")

end


local actionNumber = 0
local function ActionDone(self, data)
	local state = data.state
	local theAction = data.theAction

	if theAction and state then 
		print("Action: " .. theAction:__tostring() .. " [" .. state .. "]")
	else
		print("Action Done")
	end

	-- Cancel the DoTaskInTime for this event
	if self.currentAction ~= nil then
		self.currentAction:Cancel()
		self.currentAction=nil
	end

	-- If we're stuck on the same action (we've never pushed any new actions)...then fix it
	if state and state == "watchdog" and theAction.action.id == self.currentBufferedAction.action.id then
		print("Watchdog triggered on action " .. theAction:__tostring())
		if data.actionNum == actionNumber then 
			print("We're stuck on the same action!") 
		else
			print("We've queued more actions since then...")
		end
		self:RemoveTag("DoingLongAction")
		self:AddTag("IsStuck")
		-- What about calling
		-- inst:ClearBufferedAction() ??? Maybe this will work
		-- Though, if we're just running in place, this won't fix that as we're probably trying to walk over a river
		if theAction.target then
			self.brain:AddToIgnoreList(theAction.target.entity:GetGUID()) -- Add this GUID to the ignore list
		end
	elseif state and state == "watchdog" and theAction.action.id ~= self.currentBufferedAction.action.id then
		print("Ignoring watchdog for old action")
	end
	
	self:RemoveTag("DoingAction")
end

-- Make him execute a 'RunAway' action to try to fix his angle?
local function FixStuckWilson(inst)
	-- Just reset the whole behaviour tree...that will get us unstuck
	inst.brain.bt:Reset()
	inst:RemoveTag("IsStuck")
	if inst.components.locomotor.isrunning then
        inst.components.locomotor:StopMoving()
    end
end

-- Adds our custom success and fail callback to a buffered action
-- actionNumber is for a watchdog node

local function SetupBufferedAction(inst, action, timeout)
	if timeout == nil then 
		timeout = CurrentSearchDistance 
	end
	inst:AddTag("DoingAction")
	inst.currentAction = inst:DoTaskInTime((CurrentSearchDistance*.75)+3,function() ActionDone(inst, {theAction = action, state="watchdog", actionNum=actionNumber}) end)
	inst.currentBufferedAction = action
	action:AddSuccessAction(function() inst:PushEvent("actionDone",{theAction = action, state="success"}) end)
	action:AddFailAction(function() inst:PushEvent("actionDone",{theAction = action, state="failed"}) end)
	print(action:__tostring())
	actionNumber = actionNumber + 1
	return action	
end

--------------------------------------------------------------------------------


-- Eat sanity restoring food
-- Put sanity things on top of list when sanity is low
local function ManageSanity(brain)

	-- Quit picking up flowers all the damn time
	if brain.inst.components.sanity:GetPercent() < .9 and brain:OnIgnoreList("petals") then
		brain:RemoveFromIgnoreList("petals")
	elseif brain.inst.components.sanity:GetPercent() > .9 and not brain:OnIgnoreList("petals") then
		brain:AddToIgnoreList("petals")
	end
	
	-- TODO!!!
	if true then 
		return
	end
	
	if brain.inst.components.sanity:GetPercent() > .75 then return end
	local sanityMissing = brain.inst.components.sanity:GetMaxSanity() - brain.inst.components.sanity.current
	
	local sanityFood = brain.inst.components.inventory:FindItems(function(item) return brain.inst.components.eater:CanEat(item) 
																	and item.components.edible:GetSanity(brain.inst) > 0 end)
	
end


-----------------------------------------------------------------------
-- Go home stuff
local function HasValidHome(inst)
    return inst.components.homeseeker and 
       inst.components.homeseeker.home and 
       inst.components.homeseeker.home:IsValid()
end

local function GoHomeAction(inst)
    if  HasValidHome(inst) and
        not inst.components.combat.target then
			inst.components.homeseeker:GoHome(true)
    end
end

local function GetHomePos(inst)
    return HasValidHome(inst) and inst.components.homeseeker:GetHomePos()
end


local function AtHome(inst)
	-- Am I close enough to my home position?
	if not HasValidHome(inst) then return false end
	local dist = inst:GetDistanceSqToPoint(GetHomePos(inst))
	-- TODO: See if I'm next to a science machine
	--return inst.components.builder.current_prototyper ~= nil

	return dist <= TUNING.RESEARCH_MACHINE_DIST
end

-- Should keep track of what we build so we don't have to keep checking. 
local function ListenForBuild(inst,data)
	if data and data.item.prefab == "researchlab" then
		inst.components.homeseeker:SetHome(data.item)
	elseif data and inst.currentBufferedBuild and data.item.prefab == inst.currentBufferedBuild then
		print("Finished building " .. data.item.prefab)
		inst.currentBufferedBuild = nil
	end
	
	-- In all cases, unlock the recipe as we apparently knew how to build this
	if not inst.components.builder:KnowsRecipe(data.item.prefab) then
		print("Unlocking recipe")
		inst.components.builder:UnlockRecipe(data.item.prefab)
	end
end

-- TODO: Move this to a behaviour node
local function FindValidHome(inst)

	if not HasValidHome(inst) and inst.components.homeseeker then

		-- TODO: How to determine a good home. 
		-- For now, it's going to be the first place we build a science machine
		if inst.components.builder:CanBuild("researchlab") then
			-- Find some valid ground near us
			local machinePos = inst.brain:GetPointNearThing(inst,3)		
			if machinePos ~= nil then
				print("Found a valid place to build a science machine")
				--return SetupBufferedAction(inst, BufferedAction(inst,inst,ACTIONS.BUILD,nil,machinePos,"researchlab",nil))
				local action = BufferedAction(inst,inst,ACTIONS.BUILD,nil,machinePos,"researchlab",nil)
				inst:PushBufferedAction(action)
				
				-- Can we also make a backpack while we are here?
				if CanIBuildThis(inst,"backpack") then
					BuildThis(inst,"backpack")
				end
			
			--	inst.components.builder:DoBuild("researchlab",machinePos)
			--	-- This will push an event to set our home location
			--	-- If we can, make a firepit too
			--	if inst.components.builder:CanBuild("firepit") then
			--		local pitPos = GetPointNearThing(inst,6)
			--		inst.components.builder:DoBuild("firepit",pitPos)
			--	end
			else
				print("Could not find a place for a science machine")
			end
		end
		
	end
end


-- Find somewhere interesting to go to
local function FindSomewhereNewToGo(inst)
	-- Cheating for now. Find the closest wormhole and go there. Wilson will start running
	-- then his brain will kick in and he'll hopefully find something else to do
	local wormhole = FindEntity(inst,200,function(thing) return thing.prefab and thing.prefab == "wormhole" end)
	if wormhole then
		print("Found a wormhole!")
		inst.components.locomotor:GoToEntity(wormhole,nil,true)
		--ResetSearchDistance()
	end
end

local function MidwayThroughDusk()
	local clock = GetClock()
	local startTime = clock:GetDuskTime()
	return clock:IsDusk() and (clock:GetTimeLeftInEra() < startTime/2)
end

local function IsBusy(inst)
	return inst.sg:HasStateTag("busy")
end


local function OnHitFcn(inst,data)
	inst.components.combat:SetTarget(data.attacker)
end

-- Used by doscience node. It expects a table returned with
-- These really should be part of the builder component...but I'm too lazy to add them there. 
function ArtificalBrain:GetSomethingToBuild()
	if self.newPendingBuild then
		self.newPendingBuild = false
		return self.pendingBuildTable
	end
end

function ArtificalBrain:SetSomethingToBuild(prefab, pos, onsuccess, onfail)
	if self.pendingBuildTable == nil then
		self.pendingBuildTable = {}
	end
	
	self.pendingBuildTable.prefab = prefab
	self.pendingBuildTable.pos = pos
	self.pendingBuildTable.onsuccess = onsuccess
	self.pendingBuildTable.onfail = onfail
	self.newPendingBuild = true
end

function ArtificalBrain:OnStop()
	print("Stopping the brain!")
	self.inst:RemoveEventCallback("actionDone",ActionDone)
	self.inst:RemoveEventCallback("buildstructure", ListenForBuild)
	self.inst:RemoveEventCallback("builditem",ListenForBuild)
	self.inst:RemoveEventCallback("attacked", OnHitFcn)
	self.inst:RemoveEventCallback("noPathFound", OnPathFinder)
	self.inst:RemoveTag("DoingLongAction")
	self.inst:RemoveTag("DoingAction")
end

function ArtificalBrain:OnStart()
	local clock = GetClock()
	
	self.inst:AddComponent("cartographer")
	
	self.inst:ListenForEvent("actionDone",ActionDone)
	self.inst:ListenForEvent("buildstructure", ListenForBuild)
	self.inst:ListenForEvent("builditem", ListenForBuild)
	self.inst:ListenForEvent("attacked", OnHitFcn)
	self.inst:ListenForEvent("noPathFound", OnPathFinder)
	
	-- TODO: Make this a brain function so we can manage it dynamically
	self:AddToIgnoreList("seeds")
	self:AddToIgnoreList("petals_evil")
	self:AddToIgnoreList("marsh_tree")
	self:AddToIgnoreList("marsh_bush")
	self:AddToIgnoreList("tallbirdegg")
	self:AddToIgnoreList("pinecone")
	self:AddToIgnoreList("red_cap")
	self:AddToIgnoreList("nitre") -- Make sure to have a brain fcn add this when ready to collect it
	self:AddToIgnoreList("ash")
	
	-- If we don't have a home, find a science machine in the world and make that our home
	if not HasValidHome(self.inst) then
		local scienceMachine = FindEntity(self.inst, 10000, function(item) return item.prefab and item.prefab == "researchlab" end)
		if scienceMachine then
			print("Found our home!")
			self.inst.components.homeseeker:SetHome(scienceMachine)
		end
	end
	
	-- Things to do during the day
	local day = WhileNode( function() return clock and clock:IsDay() end, "IsDay",
		PriorityNode{
			
			-- Eat something if hunger gets below .5
			ManageHunger(self.inst, .5),
				
			-- If there's a touchstone nearby, activate it
			IfNode(function() return not IsBusy(self.inst) end, "notBusy_lookforTouchstone",
				FindAndActivate(self.inst, 25, "resurrectionstone")),
			
			-- Find a good place to call home
			IfNode( function() return not HasValidHome(self.inst) end, "no home",
				DoAction(self.inst, function() return FindValidHome(self.inst) end, "looking for home", true)),

			-- Collect stuff
			SelectorNode{

				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goPickup",
					FindResourceOnGround(self.inst, function() return self:GetCurrentSearchDistance() end)),
				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goHarvest",
					FindResourceToHarvest(self.inst,  function() return self:GetCurrentSearchDistance() end)),
				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goChop",
					FindTreeOrRock(self.inst,  function() return self:GetCurrentSearchDistance() end, ACTIONS.CHOP)),
				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goMine",
					FindTreeOrRock(self.inst,  function() return self:GetCurrentSearchDistance() end, ACTIONS.MINE)),
				
					-- Finally, if none of those succeed, increase the search distance for
					-- the next loop.
					-- Want this to fail always so we don't increase to max.
				IfNode( function() return not IsBusy(self.inst) end, "nothing_to_do",
					NotDecorator(ActionNode(function() return self:IncreaseSearchDistance() end))),
			},
				
			-- TODO: Need a good wander function for when searchdistance is at max.
			IfNode(function() return not IsBusy(self.inst) and CurrentSearchDistance == MAX_SEARCH_DISTANCE end, "maxSearchDistance",
				DoAction(self.inst, function() return FindSomewhereNewToGo(self.inst) end, "lookingForSomewhere", true)),

		},.25)
		

	-- Do this stuff the first half of duck (or all of dusk if we don't have a home yet)
	local dusk = WhileNode( function() return clock and clock:IsDusk() and (not MidwayThroughDusk() or not HasValidHome(self.inst)) end, "IsDusk",
        PriorityNode{
				
			-- Make sure we eat. During the day, only make sure to stay above 50% hunger.
			ManageHunger(self.inst,.5),
			
			-- Find a good place to call home
			IfNode( function() return not HasValidHome(self.inst) end, "no home",
				DoAction(self.inst, function() return FindValidHome(self.inst) end, "looking for home", true)),

			SelectorNode{

				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goPickup",
					FindResourceOnGround(self.inst,  function() return self:GetCurrentSearchDistance() end)),
					
				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goChop",
					FindTreeOrRock(self.inst,  function() return self:GetCurrentSearchDistance() end, ACTIONS.CHOP)),
					
				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goHarvest",
					FindResourceToHarvest(self.inst,  function() return self:GetCurrentSearchDistance() end)),

				IfNode( function() return not IsBusy(self.inst) end, "notBusy_goMine",
					FindTreeOrRock(self.inst,  function() return self:GetCurrentSearchDistance() end, ACTIONS.MINE)),
				
				IfNode( function() return not IsBusy(self.inst) end, "nothing_to_do",
					NotDecorator(ActionNode(function() return self:IncreaseSearchDistance() end))),
			},
			
			-- This is super hacky.
			IfNode(function() return not IsBusy(self.inst) and CurrentSearchDistance == MAX_SEARCH_DISTANCE end, "maxSearchDistance",
				DoAction(self.inst, function() return FindSomewhereNewToGo(self.inst) end, "lookingForSomewhere", true)),
			-- No plan...just walking around
			--Wander(self.inst, nil, 20),
        },.2)
		
		-- Behave slightly different half way through dusk
		local dusk2 = WhileNode( function() return clock and clock:IsDusk() and MidwayThroughDusk() and HasValidHome(self.inst) end, "IsDusk2",
			PriorityNode{
			
			--IfNode( function() return not IsBusy(self.inst) and  self.inst.components.hunger:GetPercent() < .5 end, "notBusy_hungry",
			--	DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating", true )),
			ManageHunger(self.inst,.5),

			IfNode( function() return HasValidHome(self.inst) end, "try to go home",
				DoAction(self.inst, function() return GoHomeAction(self.inst) end, "go home", true)),
				
			-- If we don't have a home...just
				--IfNode( function() return AtHome(self.inst) end, "am home",
				--	DoAction(self.inst, function() return BuildStuffAtHome(self.inst) end, "build stuff", true)),
				
				-- If we don't have a home, make a camp somewhere
				--IfNode( function() return not HasValidHome(self.inst) end, "no home to go",
				--	DoAction(self.inst, function() return true end, "make temp camp", true)),
					
				-- If we're home (or at our temp camp) start cooking some food.
				
				
		},.25)
		
	local night = WhileNode( function() return clock and clock:IsNight() end, "IsNight",
        PriorityNode{
			-- TODO: If we aren't home but we have a home, make a torch and keep running!
				
			-- Make sure there's light!
			MaintainLightSource(self.inst, 30),
			
			CookFood(self.inst,10),
				
			--IfNode( function() return IsNearCookingSource(self.inst) end, "let's cook",
			--	DoAction(self.inst, function() return CookSomeFood(self.inst) end, "cooking food", true)),
			
			-- Eat more at night
			--IfNode( function() return not IsBusy(self.inst) and  self.inst.components.hunger:GetPercent() < .9 end, "notBusy_hungry",
			--	DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating", true )),
			ManageHunger(self.inst,.9),
            
        },.5)
		
	-- Taken from wilsonbrain.lua
	local RUN_THRESH = 4.5
	local MAX_CHASE_TIME = 5
	local nonAIMode = PriorityNode(
    {
    	WhileNode(function() return TheInput:IsControlPressed(CONTROL_PRIMARY) end, "Hold LMB", ChaseAndAttack(self.inst, MAX_CHASE_TIME)),
    	ChaseAndAttack(self.inst, MAX_CHASE_TIME, nil, 1),
    },0)
		
	local root = 
        PriorityNode(
        {   
			-- If any brain function decides necessar, it can add an IsStuck tag to wilson. This will cause the brain to reset. 
			IfNode( function() return self.inst:HasTag("IsStuck") end, "stuck",
				DoAction(self.inst,function() print("Trying to fix this...") return FixStuckWilson(self.inst) end, "alive3",true)),
				
			-- If we ever get something in our overflow slot in the inventory, drop it.
			IfNode(function() return self.inst.components.inventory.activeitem ~= nil end, "drop_activeItem",
				DoAction(self.inst,function() self.inst.components.inventory:DropActiveItem() end, "drop",true)),
			
			-- Quit standing in the fire, idiot
			WhileNode(function() return self.inst.components.health.takingfiredamage end, "OnFire", Panic(self.inst) ),
			
			-- When hit, determine if we should fight this thing or not
			--IfNode( function() return self.inst.components.combat.target ~= nil end, "hastarget", 
			--	DoAction(self.inst,function() return FightBack(self.inst) end,"fighting",true)),
				
			-- New Combat function. 
			-- GoForTheEyes will set our combat target. If it returns true, kill
			-- TODO: Don't do this at night. He will run out into the darkness and override
			--       his need to stay in the light!
			WhileNode(function() return GoForTheEyes(self.inst) end, "GoForTheEyes", 
				ChaseAndAttack(self.inst, 10,30)),
			--DoAction(self.inst, function() return GoForTheEyes(self.inst) end, "GoForTheEyes", true),
				
			-- Always run away from these things
			RunAway(self.inst, function(guy) return ShouldRunAway(guy) end, RUN_AWAY_SEE_DIST, RUN_AWAY_STOP_DIST),

			-- Try to stay healthy
			IfNode(function() return not IsBusy(self.inst) end, "notBusy_heal", 
				ManageHealth(self.inst,.75)),
				
			-- Try to stay sane
			DoAction(self.inst,function() return ManageSanity(self) end, "Manage Sanity", true),
			
			-- Hunger is managed during the days/nights
			
			-- Prototype things whenever we get a chance
			-- Home is defined as our science machine...
			--IfNode(function() return not IsBusy(self.inst) and AtHome(self.inst) and not self.inst.currentBufferedBuild end, "atHome", 
			--	DoAction(self.inst, function() return PrototypeStuff(self.inst) end, "Prototype", true)),
			
			-- If near a science machine, wilson will prototype stuff!
			-- Otherwise, if anything is set in the buildtable, this node will build it.
			DoScience(self.inst, function() return self:GetSomethingToBuild() end),
				
			-- Always fight back or run. Don't just stand there like a tool
			WhileNode(function() return self.inst.components.combat.target ~= nil and self.inst:HasTag("FightBack") end, "Fight Mode",
				ChaseAndAttack(self.inst,20)),
			day,
			dusk,
			dusk2,
			night

        }, .25)
    
    self.bt = BT(self.inst, root)
	
	self.printDebugInfo = function(self)
		print("Items on ignore list:")
		for k,v in pairs(IGNORE_LIST) do 
			print(k,v)
		end
	end

end

return ArtificalBrain