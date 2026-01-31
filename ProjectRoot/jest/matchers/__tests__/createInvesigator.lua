-- ExaminerJestMatchers.lua
local Packages = script.Parent.Parent.Packages -- Path to your Dev Packages
local JestDiff = require(Packages.Dev.JestDiff)
local Examiner = require(game.ReplicatedStorage.Modules.Examiner)

return function(expectedLevel)
    return function(_matcherContext, callback, expectedMessage)
        local interceptedReports = {}
        
        -- 1. Create a Spy Connection
        local connection = Examiner.Signal:Connect(function(report, target, opts)
            table.insert(interceptedReports, {
                report = report,
                level = opts.level or "info"
            })
        end)

        -- 2. Run the code that is supposed to trigger Examiner
        local ok, caughtError = pcall(callback)

        -- 3. Cleanup
        connection:Disconnect()

        if not ok then error(caughtError) end

        -- 4. Validation Logic
        local foundMatch = false
        for _, entry in ipairs(interceptedReports) do
            if string.find(entry.report, expectedMessage) then
                if not expectedLevel or entry.level == expectedLevel then
                    foundMatch = true
                    break
                end
            end
        end

        -- 5. Return Result to Jest
        if foundMatch then
            return { pass = true }
        else
            return {
                pass = false,
                message = function()
                    return string.format(
                        "Expected Examiner to dispatch: %s\nBut it received: %s",
                        expectedMessage,
                        #interceptedReports > 0 and interceptedReports[1].report or "Nothing"
                    )
                end
            }
        end
    end
end
