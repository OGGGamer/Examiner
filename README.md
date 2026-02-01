# Examiner
Examiner A strong toolkit for deep inspection and debugging in Roblox. It offers live state snapshots, diffing, informer utilities, and reactive variable observation. 
It is aimed at improving project stability.
# Inspiration
The examiner module is similar to popular Roblox modules like [Promise](https://github.com/evaera/roblox-lua-promise/tree/master) and [React](https://github.com/Roblox/react-luau). 
I wanted to create a module that goes beyond finding fatal or promise errors; it inspects scripts and provides debugging information that may harm the script or highlight interesting types. 
For example, if there are errors in Roblox's API or issues with your datastore, this module will identify them. You can see how useful this could be.

Output:
```
  ---------------------------------------------------------------------------------------------
                                            EXAMINER
  ---------------------------------------------------------------------------------------------
  [Source]: <unknown>
  [Triggered By]: ServerScriptService.Server
  [Target]: userdata
  [Unexpected]: DataStores are down!
  [Instance]: Server (Script)
  ---------------------------------------------------------------------------------------------
```

Example:
```
  local Examiner = require(path.to.Examiner)
  local snapshotId = Examiner.Snapshot(playerData)

  local report, ctx = Examiner.Examine(playerData, nil, { snapshotId = snapshotId })
  print(report)
```
