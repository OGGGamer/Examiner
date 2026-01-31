return function()
	local Examiner = require(script.Parent.Examiner)

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
end
