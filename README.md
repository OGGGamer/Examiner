# Examiner
A powerful deep-inspection and debugging toolkit for Roblox. Features live state snapshotting, diffing, informer utilities, and reactive variable observation. Designed for modular project stability.
For more information go to the [Examiner Documentation](https://ogggamer.github.io/Examiner/)

# Inspiration
The examiner module is similiar to the roblox modules [Promise](https://github.com/evaera/roblox-lua-promise/tree/master) and [React](https://github.com/Roblox/react-luau), which are used a lot.
So, I decided to take a chance to make a module that instead of catching fatal or promise errors why not examine the script?

Let's say roblox's API error's or your datastore fails; it will catch that.
You can see how much this can be useful.

Output:
```
  ---------------------------------------------------------------------------------------------
                                            EXAMINER
  ---------------------------------------------------------------------------------------------
  [Source]: <unknown>
  [Triggered By]: require(game.ReplicatedStorage.Modules.Examiner).Report("DataStores are down!")
  [Target]: string
  ---------------------------------------------------------------------------------------------
    > require(game.ReplicatedStorage.Modules.Examiner).Report("DataStores are down!")
    ---------------------------------------------------------------------------------------------
                                            EXAMINER
  ---------------------------------------------------------------------------------------------
  [Source]: <unknown>
  [Triggered By]: console
  [Target]: string
```
