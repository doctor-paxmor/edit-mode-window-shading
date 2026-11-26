# Edit Mode Window Shading

I made this because Edit Mode's settings windows kept covering the frames I was trying to move.

- Double-click a window's title, or click the arrow in its top-left corner, to roll it up to just
  the title row. Do it again to open it.
- Drag a window (or its rolled-up bar) anywhere and it stays there, even when you select another
  element. Spots are saved per window title.
- Works on Blizzard's Edit Mode windows and on addon ones built the same way, like Cooldown Manager
  Centered's settings window.

`/ws reset` clears saved spots and rolled-up windows. `/ws debug` lists the windows it's tracking.

If something acts up, `/ws log on`, do the thing, then `/reload`. The log is in
`WTF/Account/<account>/SavedVariables/EditModeWindowShading.lua` (`/ws log` shows the last 20 lines
in chat). `/ws log off` when you're done.

## Install

Copy the `EditModeWindowShading` folder into `World of Warcraft/_forever_/Interface/AddOns`.
