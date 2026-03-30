# RoVM

<div align="center">
<img width="654.5" height="412" alt="image" src="https://github.com/user-attachments/assets/3f8e5d86-9469-4314-8ef8-a3f2588a9f41" />

**A custom virtual machine, mini operating system, compiler toolchain, and graphics stack built entirely inside Roblox.**

<p>
  <a href="https://github.com/Plasmism/RoVM/releases">
    <img src="https://img.shields.io/github/v/release/Plasmism/RoVM?style=for-the-badge" alt="Latest Release" />
  </a>
  <a href="https://github.com/Plasmism/RoVM/stargazers">
    <img src="https://img.shields.io/github/stars/Plasmism/RoVM?style=for-the-badge" alt="GitHub Stars" />
  </a>
  <a href="https://github.com/Plasmism/RoVM/commits/main">
    <img src="https://img.shields.io/github/last-commit/Plasmism/RoVM?style=for-the-badge" alt="Last Commit" />
  </a>
  <img src="https://img.shields.io/badge/platform-Roblox%20Studio-00A2FF?style=for-the-badge" alt="Platform Roblox Studio" />
</p>

<p>
  <a href="#overview">Overview</a> •
  <a href="#highlights">Highlights</a> •
  <a href="#bundled-software">Bundled Software</a> •
  <a href="#running-rovm">Running RoVM</a> •
  <a href="#project-layout">Project Layout</a> •
  <a href="#binary-formats">Binary Formats</a>
</p>

</div>

> Want to run it immediately?
> The **Releases** page includes a Roblox place file, so you can open RoVM directly in Studio without rebuilding the project from source.

## Overview

RoVM is a custom 32-bit virtual computer and mini operating system implemented in Luau inside Roblox.

It isn't just a bunch of ui elements cleverly put together. The project boots a complete VM environment inside Roblox with its own CPU, memory subsystem, scheduler, filesystem, syscall layer, assembler, compiler pipeline, and display stack. The result is basically a working custom OS inside Roblox.

At runtime, RoVM boots a custom userland, seeds a virtual disk, compiles bundled programs, and runs them through a scheduler on top of a custom instruction set. Programs can write to a text terminal, draw to a framebuffer, use GPU like drawing commands, load files, fork processes, and call into dynamic modules.

> Originally showcased on the Roblox DevForum:  
> https://devforum.roblox.com/t/rovm-a-virtual-computer-os-implemented-entirely-in-roblox/4317830

## Highlights

| Area | What RoVM includes |
| --- | --- |
| CPU | A custom 32-bit, byte-addressed CPU with 16 registers, kernel/user modes, branching, stack ops, syscalls, byte/halfword access, and immediate/wide instructions |
| Memory | 4 MiB of physical memory, 4 KiB pages, per-process page tables, permission checks, page faults, and copy-on-write fork support |
| Process model | Round-robin scheduling, per-process state, `fork`, `exec`, `wait`, `kill`, and zombie cleanup |
| Filesystem | A hierarchical virtual filesystem with files, directories, device nodes, file handles, and persisted saves |
| Graphics | A text device, framebuffer device, GPU command device, tiled presentation path, and app/window syscalls |
| Input | Keyboard input, control-key state, nowait reads, and mouse-aware editor interactions |
| Toolchain | A server-side C-like compiler pipeline plus a custom assembler that outputs RoVM-native binaries |
| Binary loading | `ROVM` executables plus `ROVD` images with export and relocation tables for loadable code |

## What Makes This Project Interesting

RoVM deliberately crosses a lot of layers:

- ISA design
- VM execution
- memory protection
- process scheduling
- virtual I/O devices
- binary formats
- language tooling
- operating-system-style userland
- Roblox UI and rendering integration

That mix is the point. The repository is a systems project expressed through Roblox rather than a normal Roblox game expressed through systems language.

## Architecture At A Glance

### Execution stack

1. `main.lua` builds the monitor UI, screen, memory map, devices, and boot flow.
2. `SystemImageBuilder.lua` seeds the virtual disk and compiles bundled programs.
3. `CompilerService.lua` preprocesses, tokenizes, parses, and codegens source into assembly.
4. `Assembler.lua` packs assembly into `ROVM` or `ROVD` binaries.
5. `CPU.lua`, `MMU.lua`, `PageTable.lua`, and `Scheduler.lua` execute and schedule user processes.
6. `SyscallDispatcher.lua` handles process, filesystem, text, GPU, and runtime services.

### Runtime model

- User processes run in user mode with page-table translation and permission checks.
- Kernel services execute through syscalls and MMIO-style device access.
- Files live in a virtual filesystem and can be persisted per player.
- Graphics output can go through text mode or framebuffer/GPU paths depending on the program.

## Bundled Software

RoVM ships with a seeded userspace instead of an empty shell.

### Built-in programs and demos

| Type | Included content |
| --- | --- |
| Shell | `sh` |
| Utilities | `neofetch`, `benchmark`, `calculator`, `cube` |
| Games and demos | `doom`, `bad_apple`, `snake`, `tetris`, `pong`, `space_defenders` |
| Language/runtime pieces | `python`, `py`, libc-style headers, `rovm.h`, Python runtime/header bundle |

### Seeded virtual filesystem content

RoVM populates the disk with directories and files such as:

- `/boot`
- `/bin`
- `/dev`
- `/os`
- `/usr/include`
- `/usr/lib`
- `/usr/src`

It also creates device nodes like:

- `/dev/gpu`
- `/dev/tty`

And it seeds source files and headers for the bundled software so the VM feels like a real environment rather than a hardcoded menu.

## Running RoVM

### Option 1: Use the release place file

This is the fastest path.

1. Open the [Releases](https://github.com/Plasmism/RoVM/releases) page.
2. Download the included Roblox place file.
3. Open it in Roblox Studio.
4. Press Play.

This repository intentionally keeps the source tree in Git and the place file in Releases.

### Option 2: Work from source

If you want to inspect or change the code:

1. Clone this repository.
2. Use the included [`default.project.json`](./default.project.json)
3. Sync the source tree into a Studio place.
4. Run the place in Studio.

Top-level script classes are already described in the project file:

- `StarterPlayerScripts/main` -> `LocalScript`
- `ServerScriptService/CompilerService` -> `Script`
- `ServerScriptService/FilesystemServer` -> `Script`

## Toolchain

RoVM includes both a compiler path and a binary format story.

### Compiler flow

The server-side compiler service:

1. preprocesses source
2. resolves includes
3. tokenizes input
4. parses it into an AST
5. generates RoVM assembly

That assembly is then packed by the custom assembler into a binary image the VM can execute or load.

### Assembler

`Assembler.lua` defines:

- the opcode table
- built-in MMIO/syscall labels
- directives for text/data/image layout
- `ROVM` executable output
- `ROVD` loadable output with exports and relocations

## Binary Formats

RoVM currently uses two main binary image styles:

| Format | Purpose |
| --- | --- |
| `ROVM` | Main executable format with entry point and section layout |
| `ROVD` | Loadable image format with export metadata and relocation information |

In practice this lets the project support both normal executables and dynamically loaded code with symbol lookup.

## Project Layout

```text
.
|-- ReplicatedStorage/
|   |-- VirtualMachine/
|   |   |-- Hardware/
|   |   |   |-- Core/
|   |   |   |-- Devices/
|   |   |   |-- Execution/
|   |   |   |-- MemoryManagement/
|   |   |   |-- Storage/
|   |   |   `-- System/
|   |   `-- Software/
|   |       |-- Applications/
|   |       `-- Headers/
|   `-- bad_apple.lua
|-- ServerScriptService/
|   |-- Compiler/
|   |-- CompilerService.lua
|   `-- FilesystemServer.lua
|-- StarterPlayer/
|   `-- StarterPlayerScripts/
|       |-- Modules/
|       `-- main.lua
|-- .gitignore
|-- default.project.json
`-- README.md
```

### Key files

| File | Role |
| --- | --- |
| [`StarterPlayer/StarterPlayerScripts/main.lua`](./StarterPlayer/StarterPlayerScripts/main.lua) | Bootstraps the UI, hardware, memory map, processes, and VM lifecycle |
| [`StarterPlayer/StarterPlayerScripts/Modules/SystemImageBuilder.lua`](./StarterPlayer/StarterPlayerScripts/Modules/SystemImageBuilder.lua) | Seeds the virtual disk and builds bundled software |
| [`StarterPlayer/StarterPlayerScripts/Modules/SyscallDispatcher.lua`](./StarterPlayer/StarterPlayerScripts/Modules/SyscallDispatcher.lua) | Kernel/service boundary for user programs |
| [`ReplicatedStorage/VirtualMachine/Hardware/Core/CPU.lua`](./ReplicatedStorage/VirtualMachine/Hardware/Core/CPU.lua) | CPU implementation and hot execution loop |
| [`ReplicatedStorage/VirtualMachine/Hardware/MemoryManagement/Memory.lua`](./ReplicatedStorage/VirtualMachine/Hardware/MemoryManagement/Memory.lua) | Physical memory and device mapping |
| [`ReplicatedStorage/VirtualMachine/Hardware/MemoryManagement/MMU.lua`](./ReplicatedStorage/VirtualMachine/Hardware/MemoryManagement/MMU.lua) | Address translation and copy-on-write handling |
| [`ReplicatedStorage/VirtualMachine/Hardware/Execution/Assembler.lua`](./ReplicatedStorage/VirtualMachine/Hardware/Execution/Assembler.lua) | Assembler and binary packer |
| [`ServerScriptService/CompilerService.lua`](./ServerScriptService/CompilerService.lua) | Compiler entrypoint used by the VM |

## Persistence

RoVM includes a server bridge for filesystem persistence. When used in a published Roblox experience, the virtual filesystem can be saved per player instead of resetting every boot.

## Status

RoVM is an actively iterated experimental systems project. Some parts are intentionally rough, but the repository already contains a real end-to-end machine:

- custom ISA
- assembler
- compiler service
- executable and module formats
- process model
- filesystem
- graphics
- bundled software

## License

MIT - do whatever you want, just include the license.
