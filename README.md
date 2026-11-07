# norahax / seedsowhax / hamihax / jinkihax

On-device, persistent userland exec demo through Artemis Engine visual novels

## Supported games

- `010012900d38a000` - Nora, Princess and Crying Cat 2 **Demo** https://store-jp.nintendo.com/item/software/D70010000013424 (pulled from eShop)
- `010042d022aea000` - Seedsow Lullaby **Demo** https://www.nintendo.com/us/store/products/seedsow-lullaby-switch/ (pulled from eShop)
- `0100ee5021c9e000` - Seedsow Lullaby **Full Game** (same binaries as demo — all offsets identical)
- `0100848014154000` - Hamidashi Creative **Demo** https://store-jp.nintendo.com/item/software/D70010000037967 (should be first when you type "iMel" on JP eShop)
- `0100c0501396e000` - Jinki Resurrection **Full Game**

## Setup (Demo)

Use JKSV on a Switch running Atmosphere to restore the .zip from Releases page to the console, then use the official save transfer between consoles functionality to transfer it to Switch 2.

You need one Nintendo account connected to both consoles.

It's also possible to use ns2jb with RPC to open the save and upload the files, but at time of writing not yet tested.

## Setup (Full Game)

The full game uses v1003 saves instead of v1002, so the pre-built demo saves won't work directly (they'll crash the game). A build script patches your own full-game save backup instead.

1. Use JKSV on your CFW Switch to back up your Seedsow Lullaby full game save
2. Run the build script with your backup:

```
python tools/build_fullgame.py --backup path/to/your_backup.zip --output seedsow_fullgame.zip
```

3. Restore `seedsow_fullgame.zip` with JKSV
4. Launch the game and **load save slot 1** from the load menu

The script patches the autosave's script caret to redirect execution to `inject.asb`, which bootstraps the launcher. Both autosave and save slot 1 are patched, so loading either one will trigger the launcher.

No additional offsets or binaries are needed — the full game ships the exact same main and SDK executables as the demo.

## Setup (Jinki Resurrection)

Jinki Resurrection is a separate Artemis Engine game with its own binaries and offsets. Same build-from-backup approach as the Seedsow full game.

1. Use JKSV to back up your Jinki Resurrection save
2. Run the build script:

```
python tools/build_jinki.py --backup path/to/your_jinki_backup.zip --output jinki_exploit.zip
```

3. Restore `jinki_exploit.zip` with JKSV
4. Launch Jinki Resurrection and **load save slot 1**

Jinki uses engine v1.80.mw.adv with Lua 5.3 and IndexedSave v1003.

## Updating

The launcher has a fail-safe update mechanism implemented.

The following core scripts can be updated by writing a script named `<name>2.lua`:
- `core.lua`
- `http.lua`
- `inject.lua`

In case something goes wrong you can just hold the `-` (minus) button on the controller during startup to load the original scripts.

## Interacting with HTTP server

```
$ curl -X POST http://CONSOLE_IP:8080/eval -d 'print("hello world")'

status: ok
output:
hello world
```

```
$ curl -X PUT --data-binary @file.bin "http://CONSOLE_IP:8080/save?path=save:/file.bin"
```

```
$ curl -X DELETE http://CONSOLE_IP:8080/delete?path=save:/file.bin
```

## How to update

Two options:

1. Either remake the save using the usual means (transfer or other entrypoint).

2. Use the HTTP way of upgrading:

```
$ curl -X PUT --data-binary @GAME_HERE/core.lua "http://CONSOLE_IP:8080/save?path=save:/core2.lua"
$ curl -X PUT --data-binary @common/http.lua "http://CONSOLE_IP:8080/save?path=save:/http2.lua"
$ curl -X PUT --data-binary @common/inject.lua "http://CONSOLE_IP:8080/save?path=save:/inject2.lua"
```

## FAQ

### Is it an entry point like Smilebasic 4?

Not really, this is intended to be used for convenient one-click launch of any upcoming exploit (some would call this "semi-tethered"), after you get the launcher save onto your Switch 2.

Whenever the 23.0.1 FS exploit window closes your only option to get the save on the device will be using an FS exploit triggered with another game that doesn't require a modified save, eg. Smilebasic 4 or [Civilization 7 1.0.0](https://github.com/Gezine/CivSwitch) or any other yet to be disclosed game.

### I've grabbed the full version, is it supported?

Yes! Seedsow Lullaby full game is now supported. See the "Setup (Full Game)" section above. The full game and demo use identical binaries so all exploit offsets are the same — you just need to build from your own save since the save format version differs (v1003 vs v1002).

### I missed my opportunity to grab the demos above and they're pulled from eShop!

You still can get those, though not yet supported:

- `01002eb00ce48000` - Nora Princess and Stray Cat HD **Demo** https://store-jp.nintendo.com/item/software/D70010000012253

## Credits

- KurisuWaifu - adding Hamidashi Creative support
- https://github.com/n0llptr/remote_lua_loader
- https://github.com/Gezine/ArtemisLuaLoader
- Proggy Clean TT font by Tristan Grimmer