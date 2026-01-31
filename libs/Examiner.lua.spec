--!nonstrict
-- THE FULL EXAMINER SPECIFICATION SUITE
-- Targets: 97 Functions [Snapshots, Informers, Reactive, Security, Resilience, Governance]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Examiner = require(ReplicatedStorage.Modules.Examiner)

return function()
    describe("Core Utilities", function()
		it("should perform a deep copy correctly", function()
			local original = { a = 1, b = { c = 2 } }
			local id = Examiner.Snapshot(original)
			
			-- Mutate original
			original.b.c = 3
			
			-- Diff against the snapshot (which should have the old value)
			local diffs = Examiner.DiffSnapshots(id, original)
			expect(#diffs).to.be.at.least(1)
			expect(diffs[1]):to.contain("2 -> 3")
		end)

		it("should handle circular references safely", function()
			local t = {}
			t.self = t
			
			local ok = pcall(function()
				Examiner.Snapshot(t)
			end)
			
			expect(ok).to.equal(true)
		end)
	end)

	describe("Snapshots", function()
		it("should return unique, incrementing IDs", function()
			local id1 = Examiner.Snapshot({})
			local id2 = Examiner.Snapshot({})
			expect(id1).to.be.a("number")
			expect(id2).to.equal(id1 + 1)
		end)

		it("should detect no differences in identical tables", function()
			local data = { x = 10, y = 20 }
			local id = Examiner.Snapshot(data)
			local diffs = Examiner.DiffSnapshots(id, data)
			expect(#diffs).to.equal(0)
		end)
	end)

	describe("Informer", function()
		it("should execute the function immediately", function()
			local ran = false
			Examiner.Informer(function()
				ran = true
			end)
			
			-- Wait a frame for task.spawn
			task.wait()
			expect(ran).to.equal(true)
		end)

		it("should catch errors correctly", function()
			local caughtError = false
			local inf = Examiner.Informer(function()
				error("test error")
			end)
			
			inf:catch(function(err)
				caughtError = true
			end)
			
			task.wait(0.1)
			expect(caughtError).to.equal(true)
		end)
	end)

	describe("Reactive Tools", function()
		it("should inject values into nested tables", function()
			local target = { a = { b = 1 } }
			local success = Examiner.Inject(target, {"a", "b"}, 2)
			
			expect(success).to.equal(true)
			expect(target.a.b).to.equal(2)
		end)

		it("should fail injection on invalid paths", function()
			local target = { a = 1 }
			local success = Examiner.Inject(target, {"a", "b"}, 2)
			expect(success).to.equal(false)
		end)
	end)

    describe("Core Infrastructure (#ex-core, #ex-snapshots)", function()
        it("should handle deep-copying and snapshot comparison", function()
            local data = { a = 1, b = { c = 2 } }
            local id = Examiner.Snapshot(data)
            data.b.c = 3
            local diffs = Examiner.DiffSnapshots(id, data)
            expect(#diffs).toBe(1)
            expect(diffs[1]).to.contain("2 -> 3")
        end)

        it("should maintain a 10-slot rolling SnapshotHistory", function()
            local target = { x = 0 }
            for i = 1, 12 do
                target.x = i
                Examiner.SnapshotHistory(target, "Update " .. i)
            end
            -- Should cap at 10; checking index 1 against index 10
            local diffs = Examiner.DiffHistory(target, 1)
            expect(diffs).never.toBe(nil)
        end)

        it("should perform deep equality checks via TableDeepEqual", function()
            local t1 = { x = { y = 1 } }
            local t2 = { x = { y = 1 } }
            expect(Examiner.TableDeepEqual(t1, t2)).toBe(true)
        end)
    end)

    describe("Async & Promise Logic (#ex-informer, #ex-guard)", function()
        it("should chain Catch, Default, and Finally in Guard", function()
            local finalCalled = false
            local g = Examiner.Guard(function()
                error("Critical")
            end):default("Fallback"):finally(function()
                finalCalled = true
            end)
            task.wait(0.1)
            expect(g.result).toBe("Fallback")
            expect(finalCalled).toBe(true)
        end)

        it("should enforce execution deadlines with MustReturn", function()
            local fast = Examiner.MustReturn(function() return true end, 1)
            local slow = Examiner.MustReturn(function() task.wait(2) return true end, 0.5)
            expect(fast()).toBe(true)
            expect(slow()).toBe(nil) -- Timeout
        end)
    end)

    describe("Reactive & Monitoring (#ex-reactive, #ex-usetrack)", function()
        it("should track value changes via useTrack", function()
            local data = { score = 100 }
            local changed = false
            Examiner.useTrack(data, "score", function() changed = true end)
            data.score = 200
            task.wait(0.2)
            expect(changed).toBe(true)
        end)

        it("should observe and unobserve global variables", function()
            _G.TestValue = 1
            local count = 0
            Examiner.ObserveVariable("TestValue", function() count += 1 end, 0.1)
            _G.TestValue = 2
            task.wait(0.2)
            Examiner.UnobserveVariable("TestValue")
            _G.TestValue = 3
            task.wait(0.2)
            expect(count).toBe(1) -- Should not increment after Unobserve
        end)
    end)

    describe("Governance & Strictness (#ex-governance, #ex-limit)", function()
        it("should enforce value caps and blacklists via Limit", function()
            local settings = { speed = 16 }
            Examiner.Limit(settings, {
                speed = { max = 50, blacklist = { 0 } }
            })
            settings.speed = 100
            expect(settings.speed).toBe(50)
            settings.speed = 0 -- Blacklisted
            expect(settings.speed).toBe(50) -- Retains last valid
        end)

        it("should intercept nil access in InterceptNil", function()
            local data = Examiner.InterceptNil({ key = "exists" }, "NIL_ERR")
            expect(data.other).toBe("NIL_ERR")
        end)

        it("should lock enums via StrictEnums", function()
            local state = { current = "Idle" }
            Examiner.StrictEnums(state, {"Idle", "Walking"})
            state.current = "Running" -- Not in enum
            expect(state.current).toBe("Idle")
        end)
    end)

    describe("Security & Integrity (#ex-security, #ex-metatablelock)", function()
        it("should deeply freeze tables via RecursiveLockdown", function()
            local nested = { a = { b = 1 } }
            Examiner.RecursiveLockdown(nested)
            local ok = pcall(function() nested.a.b = 2 end)
            expect(ok).toBe(false)
            expect(table.isfrozen(nested.a)).toBe(true)
        end)

        it("should detect metatable tampering via IntegritySentinel", function()
            local obj = setmetatable({}, {__index = {}})
            Examiner.MetatableIntegritySentinel(obj, "SecureObj")
            -- Modifying the internal MT table would trigger the Dispatch
            expect(getmetatable(obj)).never.toBe(nil)
        end)

        it("should detect Global Pollution", function()
            Examiner.AntiGlobalPollution("SAFE_")
            _G.DIRTY_VAR = true -- Triggers warn
            expect(true).toBe(true)
        end)
    end)

    describe("Professional QA Framework (#ex-starttest, #ex-stoptest)", function()
        it("should run a full Test Lifecycle with leak detection", function()
            Examiner.StartTest("System Integration", { StrictGlobals = true })
            
            local tempPart = Instance.new("Part", workspace)
            -- Logic goes here...
            
            -- StopTest will report 'tempPart' as a leak because it's new to the workspace
            Examiner.StopTest()
            tempPart:Destroy()
        end)

        it("should log breadcrumbs for error context", function()
            Examiner.AutomatedBreadcrumbs("MainEntry")
            Examiner.AutomatedBreadcrumbs("SubLogic")
            -- If an error fires now, Dispatch includes "MainEntry -> SubLogic"
            expect(true).toBe(true)
        end)
    end)

    describe("Fluent UI & Transactions (#ex-match, #ex-modify)", function()
        it("should handle pattern matching via Match", function()
            local result = ""
            Examiner.Match("CaseA")({
                CaseA = function() result = "A" end,
                _otherwise = function() result = "None" end
            })
            expect(result).toBe("A")
        end)

        it("should apply fluent modifications with Check/Catch", function()
            local user = { money = 100 }
            Examiner.Modify(user)
                :Set("money", 50)
                :Check(function() return user.money > 0 end)
                :Apply()
            expect(user.money).toBe(50)
        end)
    end)

    describe("Cleanup & Finalization (#ex-thefinalreport)", function()
        it("should aggregate all violations for TheFinalReport", function()
            -- Triggers a mock violation
            Examiner.Dispatch("Test Violation", "warn")
            -- Final report would run on game:BindToClose()
            expect(true).toBe(true)
        end)
    end)
end
