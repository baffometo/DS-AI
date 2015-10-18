require "brains/ai_inventory_helper"

ManageInventory = Class(BehaviourNode, function(self, inst)
   BehaviourNode._ctor(self, "ManageInventory")
   self.inst = inst
end)

function ManageInventory:Visit()

   if self.status == READY then
      -- If we don't have a backpack or are not standing near a chest...nothing to do.
      -- Not sure if basemanager should handle the chest part as there are probably 
      -- specific places to put things. Just checking backpack here.
      if not IsWearingBackpack(self.inst) then

         self.status = FAILED
         return
      end
      
      local backpack = self.inst.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
      
      -- We're wearing a backpack. Put stuff in there!
      -- Loop through our inventory and put anything we can in there.
      local inv = self.inst.components.inventory
      for k=1,inv:GetNumSlots() do
         --print("Checking slot " .. tostring(k))
         local item = inv:GetItemInSlot(k)
         if item then
            --print("Found " .. item.prefab .. " in slot")
            if ShouldGoInBackpack(item) then
               -- Just because it should go doesn't mean there is room. Find a slot.
               -- This fcn will return false if not successful. Should maybe
               -- do something with that return value...
               if TransferItemTo(item,self.inst,backpack,true) then
                  -- Maybe only do one thing at a time?
                  self.status = SUCCESS
                  return
               end
            end
         end
      end
      
      self.status = FAILED
   elseif self.status == RUNNING then
   
   end
   
end
