local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProjectRoot = script.Parent

return {
    -- Points to a file that runs BEFORE tests (good for initializing Examiner)
    setupFilesAfterEnv = { ProjectRoot.Tests.ExaminerSetup },

    -- Look for files in __tests__ folders ending in .spec or .test
    testMatch = {
        "**/__tests__/*.(spec|test)",
    },

    -- Ensure we don't run tests on the Examiner module itself unless we want to
    testPathIgnorePatterns = {
        "**/Examiner/InternalTests",
    },

    -- Pass global variables to the test environment
    globals = {
        __EXAMINER_VERSION__ = "1.0.0",
        __DEV__ = true,
    }
}