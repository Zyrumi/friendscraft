# FriendsCraft (WoW Forever)

Share professions, gold, recipes, bags and a shopping list with your friends. Install it and it does the rest by itself.

## Install

1. Close the game completely.
2. Copy the `FriendsCraft` folder into `World of Warcraft\_forever_\Interface\AddOns\`
   (the result should be `...\AddOns\FriendsCraft\FriendsCraft.toc`).
3. Start the game. On the character screen, open AddOns and check that FriendsCraft is ticked.

## Finding friends

Friends who also have FriendsCraft find you by themselves, and you choose who to share with:

- You must be on each other's friends list: the in-game friends list or Battle.net friends.
- When you log in, FriendsCraft quietly says hello to your online friends. A friend who has it shows up at the top of the Crew page ("Gigi has FriendsCraft") with **Share** and **Not now**, and a "!" appears on the minimap button.
- Nothing but your name is sent until you click Share. Data flows once you have both said yes. Not now keeps them out; you can still share later under "Show hidden". Your answer goes with who the game says they are (the Battle.net friend, or the character that whispered), never with a name or tag they only claim.
- A friend's other characters show up too, grouped under that friend, once they log in on any of them. You only need to be friends with one of their characters.
- Only friends see your data. Someone who is not on your friends list gets nothing.
- Your list follows your friends lists: remove someone as a friend and they leave your list, with what they shared.

## What you get

Open the window with the button on the minimap or by typing `/fc`. Pick its size (Small, Normal or Large) on the Settings tab; it remembers its size and place.

- **Crew:** a table of everyone, sortable by name, level or gold (click a column title). A friend with several characters is one line showing their best skill in each profession; click it to see each character. Filter by name, online only, faction or profession. Characters of the other faction are faded and show their faction crest. Crafting professions come first and gathering ones (herbalism, mining, skinning) after them. Hover an icon to see the full skill (for example 44 / 75). A "!" means it is time to visit a trainer. Cooking, first aid and fishing are hidden here, and the window uses the room to show everything a bit larger; tick "Show cooking, first aid and fishing" in the Profession menu to show them.
- **Recipes:** pick a profession on the left to see its recipes on the right, or search all recipes at once. Hover a recipe to see the materials and who in the crew has them.
- **Shopping list:** add what you need ("12 Peacebloom"). Your list comes first, then each friend's under their name. Every item shows its icon, a bar with how many you have of how many you want, and who in the crew has some or can make it. On your own items: tick the box when you've got it, use + and - to change how many (shift-click: 5 at a time), and the cross to remove it. Friends see what is still open; ticked items stay on your list until you remove them or click "Clear ticked".
- **Who has it:** search everyone's bags and banks.
- **Item tooltips:** hover any item in the game to see who in the crew has it, who needs it and who can make it.
- **Settings:** turn the minimap button or the item tooltip lines off (Settings tab, or type `/fc settings`).

## Your guild

Guildmates with FriendsCraft show up in their own section on the Crew page, in the recipe list and in "can make it" on item tooltips, marked "(guild)". With your guild you share only your professions, skills and recipes, never your bags, gold or shopping list. Turn it off in Settings ("Share professions with my guild"). Guildmates who leave the guild drop off the list.

The guild window (J) also gets a Professions tab, under its own Roster and Info tabs. It lists every guild member by profession, using the game's own record of who has what, so members show up even if they don't run FriendsCraft. Skill bars appear for those who do, the search box finds who can make a recipe, and clicking a member opens a small window with all their recipes for that profession, rarest and highest item level first. Tick "Hide white and grey" there to see only the better ones. Cooking, first aid and fishing only show for FriendsCraft users, because the game's guild list doesn't include them. The tab can also read skill and recipes for everyone from an optional data addon, FriendsCraft_Guild, that a separate helper fills from Blizzard's armory. That helper isn't part of this addon.

## Hiding people

A friend's line is named after whichever of their characters is online or was seen last. To give them a fixed name, right-click their line and pick Name this friend. Only you see that name, and leaving it empty goes back to the automatic one.

On the Crew page, right-click a friend's line and pick Hide to hide that friend with all their characters, or right-click a single character to hide just that one. Hidden people are left out of the list and the item tooltips, and they stop getting your data (what they already got stays with them). When you show them again, they catch up. Click "Show hidden" to see them again, then right-click to bring them back.

## Good to know

- **Recipes:** open each of your profession windows once. The game only shows recipes while that window is open; after that they update by themselves.
- **Bank:** bank contents update when you visit a bank.
- **Gold:** updates a few seconds after it changes.
- **Offline friends:** you see what they had the last time you were both online.
- **Combat:** sharing pauses during combat and continues afterwards.
- **Alts:** your own alts always show up for you.

## Commands

`/fc` opens the window. `/fc settings` opens its settings. `/fc help` shows a short reminder.
