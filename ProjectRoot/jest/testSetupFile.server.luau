local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Examiner = require(ReplicatedStorage.Modules.Examiner)

-- Inject into the global test environment
_G.Examiner = Examiner

-- Example: Add a custom Jest matcher that uses Examiner
-- This allows you to do: expect(myTable).toSatisfySchema(mySchema)