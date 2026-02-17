# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PolyMap is a Roblox Studio plugin that provides a terrain mesh editor. Users can create, edit, and paint triangle meshes built from thin wedge parts. It supports multiple editing modes: Select, Move, Rotate, Add, Delete, Paint, and Generate (grid generation). It outputs a `.rbxmx` plugin file built via Rojo.

## Build Commands

```bash
# Build the plugin (default build task)
rojo build -p "PolyMap v1.0.rbxmx"

# Run tests (*.spec.lua files in the Src folder)
# Tests can call t.screenshot("name") to capture the viewport (use Read tool to view the output)
# For UI tests: mount into ScreenGui parented to CoreGui, use ReactRoblox.act to flush rendering
python runtests.py

# Install dependencies (must fix the Luau types after installing)
wally install
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages
```

Tools are managed via Aftman (`aftman.toml`): Rojo 7.6.1. Dependencies are managed via Wally (`wally.toml`).

## Architecture

Three-layer design:

1. **Functionality layer** — Session lifecycle, mesh editing, 3D handles.
   - `src/createPolyMapSession.lua` — Session lifecycle: manages triangle mesh state, vertex selection, 6 editing modes, marquee selection, stroke operations, input handling via UserInputService.
   - `src/TriangleMesh.lua` — Data structure managing triangle mesh topology (vertices, triangles, edges), including workspace discovery/scanning.
   - `src/fillTriangle.lua` — Creates 1-2 thin wedge parts from 3 vertices.
   - `src/generateGrid.lua` — Generates square or triangular grids.
   - `src/getWedgeVertices.lua` — Extracts triangle vertices from thin wedge parts.
   - `src/Dragger/` — 3D handle implementations (Move, Rotate) built on DraggerFramework, with influence radius/falloff.

2. **Settings layer** — Persistent configuration via `plugin:GetSetting`/`SetSetting`.
   - `src/Settings.lua` — Settings key `"polyMapState"`. Stores mode, thickness, influence radius/falloff, grid params, paint color/material.

3. **UI layer** — React components.
   - `src/PolyMapGui.lua` — Main settings panel with mode selection and per-mode settings.
   - `src/MeshOverlay.lua` — React component rendering selected/hovered vertex markers and wireframe outlines.
   - `src/VertexMarker.lua` — SphereHandleAdornment for vertex visualization.
   - `src/PluginGui/` — Shared reusable components (copied verbatim across plugins).

**Entry point:** `loader.server.lua` creates the toolbar button and dock widget, then lazy-loads `src/main.lua` on first activation. `src/main.lua` orchestrates session management and mounts the React UI.

## Key Conventions

- All source files use `--!strict` (Luau strict type checking) and many use `--!native` (native codegen).
- Types are defined with `export type` and collected in `src/PluginGui/Types.lua` for UI-related types.
- React components use `React.createElement` (aliased as `e`) — not JSX.
- The Signal library (`Packages.Signal`) is used for custom events throughout.
- Modules typically `return` a single function rather than a table of exports.
- Undo/redo integrates with `ChangeHistoryService` using recording-based waypoints.

## Dependencies (via Wally)

- **React / ReactRoblox / RoactCompat** — UI framework
- **DraggerFramework / DraggerSchemaCore** — 3D handle/manipulator system (authored by stravant)
- **DraggerHandler** — Simple wrapper around DraggerFramework
- **Roact** — Used by DraggerToolComponent for handle rendering
- **Signal (GoodSignal)** — Event system
- **Geometry** — Geometric utilities
- **createSharedToolbar** — Optional toolbar combining with other plugins
