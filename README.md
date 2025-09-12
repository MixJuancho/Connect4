# Connect 4 – Multi‑Table World System

Server‑authoritative Connect 4 that lets multiple physical tables ("slots") run independent matches in `Workspace.PlayingSlots`.

## Core Features
* Auto‑discovery of slot models containing a `Connect4` model & `Grid` part
* Optional `Grid/Alignment` part (transparent) used for precise geometry & easy repositioning/resizing
* Dynamic column hitboxes (debug visibility toggle) & token drop animation
* Centered token & click geometry with optional `FrontOffset` attribute (studs, relative to board thickness center)
* 5s pre‑match countdown once two seats are occupied; automatic seat locking during match
* Turn timer: 25s + 10s per‑second warning; on timeout the turn is skipped (no board reset)
* Win detection returns exact 4+ chain and highlights winning tokens via `ReplicatedStorage.Highlight` (tweened fill/outline)
* Cinematic match camera (RemoteEvent `MatchCamera`) focuses on the board; restores on match end; temporarily hides players for visibility
* Token skins & subtle hue shift if both players choose the same skin
* Safe cleanup & automatic reset after each match

## Repository Layout (Essentials)
```
ReplicatedStorage/
	Connect4/ (Folder)
		Narrate (RemoteEvent)
		MatchCamera (RemoteEvent)
	Tokens/ (Folder with at least Red, Yellow)
	Highlight (Highlight)  <-- optional but enables win chain effect
Workspace/
	PlayingSlots/
		<SlotModel>/
			Connect4/
				Grid (Part or Model)
				Alignment (Part, optional)
			(Two Seat descendants somewhere under slot)
ServerScriptService/
	Server/
		Connect4.server.luau
StarterPlayer/StarterPlayerScripts/
	Connect4.client.luau
```

## Quick Start
1. Place your slot models under `Workspace.PlayingSlots` (each with two seats & `Connect4` model containing a `Grid` part).
2. (Optional) Add a transparent `Alignment` part inside `Grid` and size/position it: gameplay geometry uses this instead of `Grid` automatically.
3. Ensure token models exist under `ReplicatedStorage/Tokens` (at least `Red` and `Yellow`).
4. (Optional) Add a `Highlight` instance under `ReplicatedStorage` for win highlighting.
5. Press Play: sit two players; watch countdown, camera focus, and begin placing tokens.

## Attributes
* `FrontOffset` (number) on `Grid` or `Alignment`: shifts tokens & hitboxes along board normal (positive toward board's front normal). Default = 0.

## Development (Rojo)
Build a place file:
```bash
rojo build -o "4 in a row.rbxlx"
```
Serve live sync:
```bash
rojo serve
```

More: https://rojo.space/docs

## License
Add a license of your choice (currently unspecified).
