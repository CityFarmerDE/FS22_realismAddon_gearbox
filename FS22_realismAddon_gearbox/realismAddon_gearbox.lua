-- by modelleicher ( Farming Agency )


realismAddon_gearbox = {};

local MAX_ACCELERATION_LOAD = 0.8

-- completely overwrite getLastModulatedMotorRpm to remove the RPM-lowering effect on load-changes. This seems to be done on purpose by Giants for whatever reason. 
-- I don't think we need anything in that function so just return unmodified lastMotorRpm (to try, maybe return lastRealMotorRpm instead even) 
-- this is active no matter what as soon as this script is active while other functions only activate when MANUAL + CLUTCH setting is active 
function realismAddon_gearbox.newGetLastModulatedMotorRpm(self, superFunc)
    return self.lastMotorRpm
end
VehicleMotor.getLastModulatedMotorRpm = Utils.overwrittenFunction(VehicleMotor.getLastModulatedMotorRpm, realismAddon_gearbox.newGetLastModulatedMotorRpm)


-- gearbox adjustments - notes 

-- remove all automatic braking - done 
-- add auto acceleration below min rpm - done 
-- brake and acc pedal still works fine - done 
-- figure out why rpm is above minRpm now - done 
-- wheel rpm -> diff rpm -> clutch rpm -> motor rpm realignment - done 
-- load add-in when neutral or clutch - done
-- check clutch engagement how/where what - done
-- add clutch-feel from RMT, make clutch slippable - done 
-- hand throttle add in - done
-- added fps axis shifting, analog axis for gear selection - done 
-- check and override pto rpm stuff - done 
-- stop running away when motor off - done 

-- smaller fixes 
-- currentGearRatio set to 0 if in neutral, remove jerking when clutch is released in neutral - done 
-- added smoothing of acceleration value to stabilize rpm and load and lastAcceleratorPedal

-- updateGear function seems to be the only one where clutch ratio has influence on gear ratio #M1 - yep, that solved it 

-- things to add and consider	
-- 		work out a way to calculate and interpolate between forward-reverse when vehicle is moving and clutch is pressed to stop vehicle from sudden stop when starting to engage clutch and vehicle rolls in opposite speed 

-- wrong RPM calculation between clutchValue 0.8 and 0.9 -- made clutch completely disengaged at 0.8 solves this.. don't have any other way atm since thats a engine function that returns the wrong value and I don't know which values influence that if any 

-- notes end 


-- better clutch feel 
function realismAddon_gearbox.calculateClutchRatio(self, motor)
	
	-- the end of this function will determine the actual gear ratio 
	local actualGearRatio = 0

	-- first get the current theoretical gear ratio based on wheel speed 	
	local wheelSpeed = 0;
	local numWheels = 0;
	for _, wheel in pairs(self.spec_wheels.wheels) do

		local rpm = getWheelShapeAxleSpeed(wheel.node, wheel.wheelShape)*30/math.pi
		wheelSpeed = wheelSpeed + (rpm * wheel.radius);
		numWheels = numWheels + 1;
		
	end;	
	wheelSpeed = wheelSpeed / numWheels;	
	
	-- :wheelSpeed is now the signed average speed of all wheels 
	
	-- use that to calculate the current gear ratio 
	local currentGearRatio = motor.lastMotorRpm / wheelSpeed
	
	-- :currentGearRatio is now the actual true ratio between wheels average and motor 
	
	-- cap the currentRatio since if the ratio is too big physics act weird 
	if currentGearRatio < 0 then
		currentGearRatio = math.max(currentGearRatio, -1000)
	else
		currentGearRatio = math.min(currentGearRatio, 1000)
	end
	
	-- get the wanted gear Ratio 
	local wantedGearRatio = 0
	if motor.currentGears[motor.gear] ~= nil then
		wantedGearRatio = motor.currentGears[motor.gear].ratio * motor:getGearRatioMultiplier()
	end	
	
	-- if we are in neutral currentGearRatio is set to 0 as well no matter what 
	if wantedGearRatio == 0 then
		currentGearRatio = 0
	end
	
	
	-- smoothing maybe 
	if motor.lastGearRatioME == nil then
		motor.lastGearRatioME = currentGearRatio
	end
	motor.lastGearRatioME = motor.lastGearRatioME * 0.9 + currentGearRatio * 0.1
		
	
	-- :wantedGearRatio is now the signed wanted ratio 
	
	-- manualClutchValue is inverted so 0 is closed 1 is open 
	if motor.manualClutchValue < 0.01 then -- clutch is closed, use wantedGearRatio for actualGearRatio
		actualGearRatio = wantedGearRatio
	else -- if clutch is at least partially opened, use the ratio calculation including the clutch value 
	
		-- invert back to 0-1 value where 1 is closed 
		local manualClutchValueInvert = 1 - motor.manualClutchValue
		
		-- clutch non-linear and cap at 1
		manualClutchValueInvert = math.min(manualClutchValueInvert * manualClutchValueInvert, 1);		
		
		-- interpolate between wanted and actual ratio according to clutch value 
		actualGearRatio = (wantedGearRatio * manualClutchValueInvert) + (motor.lastGearRatioME * (1-manualClutchValueInvert))
		
		-- cap actual ratio at wanted 
		if wantedGearRatio < 0 then
			-- smaller negative value = higher ratio so cap at min 
			actualGearRatio = math.min(actualGearRatio, wantedGearRatio)
		else
			actualGearRatio = math.max(actualGearRatio, wantedGearRatio)
		end
		
		-- TO DO :instead of using wanted as cap, calculate ratio when wanted is another direction than actual such that vehicle slows down and accelerates in opposite direction at a realistic feeling rate 
			
	end

	motor.maxGearRatio = actualGearRatio
	motor.minGearRatio = actualGearRatio

end

-- function to return if vehicle and settings are manual 
function realismAddon_gearbox.checkIsManual(motor)
	
	local isManualTransmission = motor.backwardGears ~= nil or motor.forwardGears ~= nil
	if isManualTransmission and VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH then	
		return true
	else
		return false
	end
end

-- remove ptoRpm to minRpm change 
function realismAddon_gearbox.getRequiredMotorRpmRange(self, superFunc)
	
	if realismAddon_gearbox.checkIsManual(self) then
		return self.minRpm, self.maxRpm
	else
		return superFunc(self)
	end

end
VehicleMotor.getRequiredMotorRpmRange = Utils.overwrittenFunction(VehicleMotor.getRequiredMotorRpmRange, realismAddon_gearbox.getRequiredMotorRpmRange)

-- VehicleMotor.update
function realismAddon_gearbox.update(self, superFunc, dt)


	-- do our custom stuff only if we are in SHIFT_MODE_MANUAL_CLUTCH and in a vehicle with manual transmission
	if realismAddon_gearbox.checkIsManual(self) then	
		
		local vehicle = self.vehicle
		
		-- base stuff 
		if next(vehicle.spec_motorized.differentials) ~= nil and vehicle.spec_motorized.motorizedNode ~= nil then
			local lastMotorRotSpeed = self.motorRotSpeed
			local lastDiffRotSpeed = self.differentialRotSpeed
			self.motorRotSpeed, self.differentialRotSpeed, self.gearRatio = getMotorRotationSpeed(vehicle.spec_motorized.motorizedNode)
			
			-- if clutch is disengaged more than 80% getMotorRotationSpeed will return wrong values for the motor rot speed, it will always return max rpm not sure why 
				
			
			if g_physicsDtNonInterpolated > 0 and not getIsSleeping(vehicle.rootNode) then
				self.lastMotorAvailableTorque, self.lastMotorAppliedTorque, self.lastMotorExternalTorque = getMotorTorque(vehicle.spec_motorized.motorizedNode)
			end
			
			
			local motorRotAcceleration = (self.motorRotSpeed - lastMotorRotSpeed) / (g_physicsDtNonInterpolated * 0.001)
			self.motorRotAcceleration = motorRotAcceleration
			self.motorRotAccelerationSmoothed = 0.8 * self.motorRotAccelerationSmoothed + 0.2 * motorRotAcceleration
			
			local diffRotAcc = (self.differentialRotSpeed - lastDiffRotSpeed) / (g_physicsDtNonInterpolated * 0.001)
			self.differentialRotAcceleration = diffRotAcc
			self.differentialRotAccelerationSmoothed = 0.95 * self.differentialRotAccelerationSmoothed + 0.05 * diffRotAcc	
		
			
			self.motorExternalTorque = self.lastMotorExternalTorque
			self.motorAppliedTorque = self.lastMotorAppliedTorque
			self.motorAvailableTorque = self.lastMotorAvailableTorque
			
			self.motorAppliedTorque = self.motorAppliedTorque - self.motorExternalTorque	
			self.motorExternalTorque = math.min(self.motorExternalTorque * self.externalTorqueVirtualMultiplicator, self.motorAvailableTorque - self.motorAppliedTorque)			
			self.motorAppliedTorque = self.motorAppliedTorque + self.motorExternalTorque
			
			self.requiredMotorPower = math.huge
			
		else
			local _, gearRatio = self:getMinMaxGearRatio()
			self.differentialRotSpeed = WheelsUtil.computeDifferentialRotSpeedNonMotor(vehicle)
			self.motorRotSpeed = math.max(math.abs(self.differentialRotSpeed * gearRatio), 0)
			self.gearRatio = gearRatio
		end
		
		local clampedMotorRpm = math.max(self.motorRotSpeed*30/math.pi, self.minRpm)
		

		-- lastMotorRpm is smoothed
		-- lastRealMotorRpm is not smoothed 

				
		-- modelleicher 
		-- if clutch is pressed, motor RPM is not dependent on wheel speed anymore.. Instead, calculate motor RPM based on accelerator pedal input 
		if self.manualClutchValue > 0.1 or self:getIsInNeutral() then		
			
			local clutchPercent = 1 - self.manualClutchValue
			
			if self:getIsInNeutral() then
				clutchPercent = 0
			end
			
			local accInput = 0
			if vehicle.getAxisForward ~= nil then
				accInput = math.max(0, vehicle:getAxisForward())
			end
			
			-- take hand throttle into account -- TO DO
			if vehicle.spec_realismAddon_gearbox_inputs ~= nil then	
				accInput = math.max(accInput, vehicle.spec_realismAddon_gearbox_inputs.handThrottlePercent)
			end
			

			local wantedRpm = (self.maxRpm - self.minRpm) * accInput + self.minRpm;
			local currentRpm = self.lastRealMotorRpm;
			if currentRpm < wantedRpm then
				currentRpm = math.min(currentRpm + ((self.maxRpm - self.minRpm) / 650) * dt, wantedRpm);  -- not perfect, but better if vehicles have different rpm ranges, e.g. cars
			elseif currentRpm > wantedRpm then
				currentRpm = math.max(currentRpm - ((self.maxRpm - self.minRpm) / 1300) * dt, wantedRpm);
			end;	

			
			if clutchPercent < 0.2 then -- below 20% the clutch is fully opened, just use our RPM calculation    -- 0.8 manual clutch value -
				clampedMotorRpm = currentRpm;
	
			elseif clutchPercent < 0.8 then -- up to 80% the clutch can still slip a lot, use fixed percentage 	-- 0.2 manual clutch value 
				clampedMotorRpm = (clampedMotorRpm * 0.1) + (currentRpm * 0.9);
				
			else	-- everything else 
				clampedMotorRpm = (clampedMotorRpm * ((clutchPercent-0.2)*1.25)) + (currentRpm * (1-((clutchPercent-0.2)*1.25)));
			end;			
			
		else
		
			-- get clutch RPM shut off motor if RPM gets too low , disable "auto clutch" of FS
			local clutchRpm = math.abs(self:getClutchRotSpeed() *  9.5493);
			
			-- set rpm to clutch rpm if clutch rpm is smaller than min rpm (this doesn't work on Multiplayer)
			if clutchRpm < self.minRpm and clutchRpm > 0 then -- only if not 0 cause Multiplayer 
				clampedMotorRpm = (self.lastRealMotorRpm * 0.7) + (clutchRpm * 0.3);
			end;		
			
			
			-- this doesn't work like that in FS22, so disable for now. Set clampedMotorRpm to minRpm if vehicle is stopped anyways 
			if clutchRpm <= 0 and vehicle.isServer then -- check if we're server 
				--vehicle:stopMotor()
				clampedMotorRpm = self.minRpm;
			end;
			
			-- same as above 
			if clampedMotorRpm <= 0 then
				--vehicle:stopMotor()
				clampedMotorRpm = self.minRpm;
				self.lastRealMotorRpm = self.minRpm;
			end;	

			-- clamp so no negative value 
			clampedMotorRpm = math.max(clampedMotorRpm, 0)	

		end
		
		-- finally set the new RPM values
		if vehicle.isServer then	

			-- setLastRpm does have some smoothing included 	
			-- we do some smoothing before anyways because otherwise it will false-register fast rpm changes and inject load 
			-- TO DO :check if we deactivate the smoothing on dedicated servers because due to synching its all slower anyways and already reacts slower than we want 
			if self.clampedMotorRpm == nil then
				self.clampedMotorRpm = clampedMotorRpm
			end
			self.clampedMotorRpm = self.clampedMotorRpm * 0.6 + clampedMotorRpm * 0.4
			
			-- set last rpm 
			self:setLastRpm(self.clampedMotorRpm)

			self.lastPtoRpm = self.clampedMotorRpm;			
		
			-- for the equalizedMotorRpm we want heavy smoothing still, though not sure what equalizedMotorRpm is used for in Fs22 I don't think much, maybe in multiplayer  
			self.equalizedMotorRpm = (self.equalizedMotorRpm * 0.9) + ( 0.1 * clampedMotorRpm);
		end		
	
		
		if vehicle.isServer then
		
			-- load calculation by Giants, this doesn't look bad at all 
			
			-- raw and buffer 
			local rawLoadPercentage = self:getMotorAppliedTorque() / math.max(self:getMotorAvailableTorque(), 0.0001)
			self.rawLoadPercentageBuffer = self.rawLoadPercentageBuffer + rawLoadPercentage
			self.rawLoadPercentageBufferIndex = self.rawLoadPercentageBufferIndex + 1

			if self.rawLoadPercentageBufferIndex >= 2 then
				self.rawLoadPercentage = self.rawLoadPercentageBuffer / 2
				self.rawLoadPercentageBuffer = 0
				self.rawLoadPercentageBufferIndex = 0
			end
			
			-- downhill / push 
			if self.rawLoadPercentage < 0.01 and self.lastAcceleratorPedal < 0.2 and (not self.backwardGears and not self.forwardGears or self.gear ~= 0 or self.targetGear == 0) then
				self.rawLoadPercentage = -1
			else
				-- min idle load 
				local idleLoadPct = 0.05
				self.rawLoadPercentage = (self.rawLoadPercentage - idleLoadPct) / (1 - idleLoadPct)
			end
			
			-- modelleicher
			-- add in load percentage if engine is accelerating in neutral or with clutch pressed 
			local clutchPercent = 1 - self.manualClutchValue
			local currentRpm = self.lastRealMotorRpm;
			local mAxisForward = 0
			if vehicle.getAxisForward ~= nil then
				mAxisForward = math.max(0, vehicle:getAxisForward())
			end			
			
			-- if clutch is pressed or neutral, load percentage is calculated using wanted and actual RPM 
			if clutchPercent < 0.6 or self:getIsInNeutral() then
				local loadNeutral
				if (currentRpm / self.maxRpm) < mAxisForward then
					loadNeutral = 1;
				else
					loadNeutral = 0;
				end;
				self.rawLoadPercentage = math.max(self.rawLoadPercentage, loadNeutral)
			end;			
			
			-- modelleicher end 
			
			-- Giants add in acceleration percentage, I think this is something that would've improved load calc in RMT 
			local accelerationPercentage = math.min(self.vehicle.lastSpeedAcceleration * 1000 * 1000 * self.vehicle.movingDirection / self.accelerationLimit, 1)

			if accelerationPercentage < 0.95 and self.lastAcceleratorPedal > 0.2 then
				self.accelerationLimitLoadScale = 1
				self.accelerationLimitLoadScaleTimer = self.accelerationLimitLoadScaleDelay
			elseif self.accelerationLimitLoadScaleTimer > 0 then
				self.accelerationLimitLoadScaleTimer = self.accelerationLimitLoadScaleTimer - dt
				local alpha = math.max(self.accelerationLimitLoadScaleTimer / self.accelerationLimitLoadScaleDelay, 0)
				self.accelerationLimitLoadScale = math.sin((1 - alpha) * 3.14) * 0.85
			end

			if accelerationPercentage > 0 then
				self.rawLoadPercentage = math.max(self.rawLoadPercentage, accelerationPercentage * self.accelerationLimitLoadScale)
			end
			

			self.constantAccelerationCharge = 1 - math.min(math.abs(self.vehicle.lastSpeedAcceleration) * 1000 * 1000 / self.accelerationLimit, 1)

			if self.rawLoadPercentage > 0 then
				self.rawLoadPercentage = self.rawLoadPercentage * MAX_ACCELERATION_LOAD + self.rawLoadPercentage * (1 - MAX_ACCELERATION_LOAD) * self.constantAccelerationCharge
			end		
			
		end

		self:updateSmoothLoadPercentage(dt, self.rawLoadPercentage)	
		
		

	else
		return superFunc(self, dt)
	end
	
end
VehicleMotor.update = Utils.overwrittenFunction(VehicleMotor.update, realismAddon_gearbox.update)



function realismAddon_gearbox.updateWheelsPhysics(self, superFunc, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
	

	-- do our custom stuff only if we are in SHIFT_MODE_MANUAL_CLUTCH and in a vehicle with manual transmission
	if realismAddon_gearbox.checkIsManual(self.spec_motorized.motor) then		
	
		local motor = self.spec_motorized.motor
	
		-- back up acceleration variable before we do any changes to it, we need this later for braking 
		local accBackup = acceleration
		
		-- acc and brake pedal init 
		local acceleratorPedal = 0
		local brakePedal = 0	
		
		
		--
		local handThrottlePercent = 0
		if self.spec_realismAddon_gearbox_inputs ~= nil then	
			handThrottlePercent = self.spec_realismAddon_gearbox_inputs.handThrottlePercent
		end		
		--
		
		local newWantedAcceleration = 0
		-- use acceleration as rpm setting 
		if acceleration >= 0 then -- we are not braking 
		
			-- if hand throttle is more than acceleration, use hand throttle value 
			acceleration = math.max(acceleration, handThrottlePercent)
			
			-- calculate the currently wanted RPM depending on acceleration (e.g. pedal position)
			local wantedRpm = (motor.maxRpm - motor.minRpm) * acceleration + motor.minRpm
			
			
			-- if our wantedRPM is higher than the currentRPM, increase acceleration, if its lower, decrease acceleration
			if wantedRpm > motor.lastRealMotorRpm then
				newWantedAcceleration = 1
			else
				newWantedAcceleration = 0
			end;
		
		end;
		
		acceleration = newWantedAcceleration
		
		-- if engine rpm falls below minRpm acceleration is 1
		if acceleration >= 0 and motor.lastRealMotorRpm <= (motor.minRpm +2) then
			acceleration = 1
		end;	
		
		-- if we are in neutral, acceleration is 0
		if motor:getIsInNeutral() then
			acceleration = 0
		end
		
		-- if clutch is disengaged, acceleration is 0
		if motor:getManualClutchPedal() > 0.8 then
			acceleration = 0
		end
		
		-- if motor is off, no acceleration 
		if not self:getIsMotorStarted() then
			acceleration = 0
		end
		
		-- smoothing acceleration (V 0.5.1.0 addition)
		if motor.lastAccelerationME == nil then
			motor.lastAccelerationME = acceleration
		end
		motor.lastAccelerationME = motor.lastAccelerationME * 0.9 + acceleration * 0.1
		

		-- set accelerationPedal desired value 
		if acceleration > 0 then
			acceleratorPedal = acceleration
		end
		
		-- set brake pedal desired value  
		if accBackup < 0 then
			brakePedal = math.abs(accBackup)
		end
		-- 		
		
		-- hand brake 
		if doHandbrake then
			brakePedal = 1
		end
		
		-- Enhanced Vehicle Handbrake if Enhanced Vehicle is active 
		if self.vData ~= nil then
			if self.vData.is[13] then
				brakePedal = 1
				doHandbrake = true
			end
		end
		
		-- #M1  -- in updateGear the current clutch ratio influences the current gear ratio 
				-- also it seems to be only called here, so instead of overwriting the entire function I can just do a new ratio calculation here 
		acceleratorPedal, brakePedal = motor:updateGear(acceleratorPedal, brakePedal, dt)
		
		-- better clutch feel, new ratio calc 
		realismAddon_gearbox.calculateClutchRatio(self, motor)
		
		
		-- smoothing for lastAcceleratorPedal since the acceleratorPedal is on/off with my calculation, even with smoothing the load-changes are too fast (V 0.5.1.0 addition)
		if motor.lastAcceleratorPedalME == nil then
			motor.lastAcceleratorPedalME = motor.lastAcceleratorPedal
		end
		motor.lastAcceleratorPedalME = motor.lastAcceleratorPedalME * 0.9 + acceleratorPedal * 0.1
		
		motor.lastAcceleratorPedal = motor.lastAcceleratorPedalME
		--
		
		
		

		SpecializationUtil.raiseEvent(self, "onVehiclePhysicsUpdate", acceleratorPedal, brakePedal, automaticBrake, currentSpeed)


		--acceleratorPedal, brakePedal = WheelsUtil.getSmoothedAcceleratorAndBrakePedals(self, acceleratorPedal, brakePedal, dt)		
		
		-- basegame stuff 
		if next(self.spec_motorized.differentials) ~= nil and self.spec_motorized.motorizedNode ~= nil then
		
			local absAcceleratorPedal = math.abs(acceleratorPedal)
			local minGearRatio, maxGearRatio = motor:getMinMaxGearRatio()
			
			local maxSpeed = nil
			if maxGearRatio >= 0 then
				maxSpeed = motor:getMaximumForwardSpeed()
			else
				maxSpeed = motor:getMaximumBackwardSpeed()
			end
			
			maxSpeed = math.min(maxSpeed, motor:getSpeedLimit() / 3.6)
			local maxAcceleration = motor:getAccelerationLimit()
			local maxMotorRotAcceleration = motor:getMotorRotationAccelerationLimit()
			local minMotorRpm, maxMotorRpm = motor:getRequiredMotorRpmRange()
			local neededPtoTorque, ptoTorqueVirtualMultiplicator = PowerConsumer.getTotalConsumedPtoTorque(self)
			neededPtoTorque = neededPtoTorque / motor:getPtoMotorRpmRatio()
			local neutralActive = minGearRatio == 0 and maxGearRatio == 0 or motor:getManualClutchPedal() > 0.9
			motor:setExternalTorqueVirtualMultiplicator(ptoTorqueVirtualMultiplicator)
			
			if not neutralActive then
				self:controlVehicle(absAcceleratorPedal, maxSpeed, maxAcceleration, minMotorRpm * math.pi / 30, maxMotorRpm * math.pi / 30, maxMotorRotAcceleration, minGearRatio, maxGearRatio, motor:getMaxClutchTorque(), neededPtoTorque)
			else
				self:controlVehicle(0, 0, 0, 0, math.huge, 0, 0, 0, 0, 0)

				brakePedal = math.max(brakePedal, 0.03)
			end
		end

		self:brake(brakePedal)		
		
		
	else
		superFunc(self, dt, currentSpeed, acceleration, doHandbrake, stopAndGoBraking)
	end
end
WheelsUtil.updateWheelsPhysics = Utils.overwrittenFunction(WheelsUtil.updateWheelsPhysics, realismAddon_gearbox.updateWheelsPhysics)

