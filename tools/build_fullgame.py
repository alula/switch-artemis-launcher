#!/usr/bin/env python3
"""Build an artemis-launcher save for the Seedsow Lullaby full game.

Takes a JKSV backup of the full game and patches it to redirect script
execution to inject.asb on load. The full game and demo share identical
main/SDK binaries, so all exploit offsets carry over unchanged.

Usage:
    python tools/build_fullgame.py --backup path/to/jksv_backup.zip [--output seedsow_fullgame.zip]

The backup must contain at least: autosave.dat, saveg.dat, system.dat,
save0001.dat, save0001.png, save0001_s.png, .nx_save_meta.bin
"""
import argparse
import struct
import sys
import zipfile
import zlib
from pathlib import Path


# --- Minimal indexed-save parser (BOWS/BOWG/BOWX v1002/v1003) ---

def _u32(value):
    return struct.pack('<I', value)

def _string(value):
    if isinstance(value, str):
        value = value.encode('utf-8')
    return _u32(len(value)) + value

class _Edit:
    __slots__ = ('start', 'before', 'after')
    def __init__(self, start, before, after):
        self.start = start
        self.before = before
        self.after = after

class IndexedSave:
    def __init__(self, data):
        self.magic, self.version, size = struct.unpack_from('<4sII', data)
        if self.magic not in (b'BOWS', b'BOWG', b'BOWX') or self.version not in (1002, 1003):
            raise ValueError('Unsupported save format')
        obj = zlib.decompressobj()
        self.body = obj.decompress(data[12:]) + obj.flush()
        if len(self.body) != size:
            raise ValueError('Decompressed size mismatch')
        self.index_start = struct.unpack_from('<I', self.body, len(self.body) - 4)[0]
        self.fields = self.body[:self.index_start]
        cursor = self.index_start

        def read():
            nonlocal cursor
            value = struct.unpack_from('<I', self.body, cursor)[0]
            cursor += 4
            return value

        self.groups = {}
        for _ in range(read()):
            base, length = read(), read()
            entries = {}
            for _ in range(length):
                key, offset = read(), read()
                entries[key] = offset
            self.groups[base] = entries

    @staticmethod
    def _make_body(fields, groups):
        index = bytearray(_u32(len(groups)))
        for base, entries in groups.items():
            index += _u32(base) + _u32(len(entries))
            for key, offset in entries.items():
                index += _u32(key) + _u32(offset)
        return fields + index + _u32(len(fields))

    def lp(self, offset):
        size = struct.unpack_from('<I', self.fields, offset)[0]
        return self.fields[offset + 4:offset + 4 + size]

    def apply(self, edits):
        edits = sorted(edits, key=lambda e: e.start)
        prev_end = 0
        parts = []
        for edit in edits:
            end = edit.start + len(edit.before)
            if self.fields[edit.start:end] != edit.before:
                raise ValueError(f'Field mismatch at offset {edit.start}')
            parts += [self.fields[prev_end:edit.start], edit.after]
            prev_end = end
        parts.append(self.fields[prev_end:])
        fields = b''.join(parts)

        def relocate(offset):
            delta = 0
            for edit in edits:
                if offset <= edit.start:
                    break
                delta += len(edit.after) - len(edit.before)
            return offset + delta

        groups = {relocate(b): {k: relocate(o) for k, o in ents.items()}
                  for b, ents in self.groups.items()}
        body = self._make_body(fields, groups)
        return self.magic + _u32(self.version) + _u32(len(body)) + zlib.compress(body, 9)


# --- Minimal ASB encoder ---

def encode_asb(commands):
    data = bytearray(b'ASB\0\0' + _u32(len(commands)))
    for line, (name, params) in enumerate(commands, 1):
        data += _u32(0) + _string(name) + b'\0' + _u32(line) + _u32(len(params))
        for key, value in params.items():
            data += _string(key) + b'\0' + _string(value) + b'\0'
    return bytes(data)


# --- Build logic ---

INJECT_LUA_SOURCE = '''\
function include_lua(engine)
    e = engine
    local update_path = "save:/inject2.lua"
    local should_load_update = e:isFileExists(update_path)
    _G.n2h_was_recovery = false
    if e:isDown(114) then
        should_load_update = false
        _G.n2h_was_recovery = true
    end
    if should_load_update then
        print("loading update from " .. update_path)
        e:include(update_path)
    else
        e:include("save:/inject.lua")
    end
end'''


def patch_autosave(data):
    """Patch autosave to redirect script execution to save:/inject.asb."""
    save = IndexedSave(data)
    root = save.groups[0]
    caret = save.groups[root[3]]

    script = save.lp(caret[3])
    if script != b'system/script.asb':
        raise ValueError(f'Unexpected caret script: {script!r} (expected system/script.asb)')

    caret1 = struct.unpack_from('<I', save.fields, caret[1])[0]
    caret4 = struct.unpack_from('<I', save.fields, caret[4])[0]

    edits = [
        _Edit(caret[3], _string('system/script.asb'), _string('save:/inject.asb')),
    ]
    if caret1 != 0:
        edits.append(_Edit(caret[1], _u32(caret1), _u32(0)))
    if caret4 != 1:
        edits.append(_Edit(caret[4], _u32(caret4), _u32(1)))

    for key, name in {34: 'vsync', 38: 'keyClickStart', 50: 'keyClickEnd',
                      69: 'store', 70: 'restore', 80: 'exskip_end'}.items():
        try:
            if save.lp(root[key]) == name.encode():
                edits.append(_Edit(root[key], _string(name), _string('')))
        except (KeyError, IndexError):
            pass

    return save.apply(edits)


def build(backup_path, output_path):
    backup_path = Path(backup_path)
    common = Path(__file__).resolve().parent.parent / 'common'

    required = {'autosave.dat', 'saveg.dat', 'system.dat',
                'save0001.dat', 'save0001.png', 'save0001_s.png'}

    files = {}
    with zipfile.ZipFile(backup_path) as zf:
        names = {Path(n).name: n for n in zf.namelist() if not zf.getinfo(n).is_dir()}
        for req in required:
            if req not in names:
                print(f'error: backup is missing {req}', file=sys.stderr)
                sys.exit(1)
            files[req] = zf.read(names[req])
        if '.nx_save_meta.bin' in names:
            files['.nx_save_meta.bin'] = zf.read(names['.nx_save_meta.bin'])

    # Verify it's a full-game save (v1003)
    save = IndexedSave(files['autosave.dat'])
    if save.version < 1003:
        print(f'warning: save version is {save.version}, expected 1003 for full game', file=sys.stderr)

    # Patch autosave
    patched = patch_autosave(files['autosave.dat'])
    print(f'patched autosave.dat ({len(files["autosave.dat"])} -> {len(patched)} bytes)')

    # Compile inject.iet -> inject.asb
    inject_asb = encode_asb([
        ('lua', {'script': INJECT_LUA_SOURCE}),
        ('calllua', {'function': 'include_lua'}),
        ('return', {}),
    ])
    print(f'compiled inject.asb ({len(inject_asb)} bytes)')

    # Build output zip
    output_path = Path(output_path)
    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        if '.nx_save_meta.bin' in files:
            zf.writestr('.nx_save_meta.bin', files['.nx_save_meta.bin'])
        zf.writestr('autosave.dat', patched)
        zf.writestr('save0001.dat', patched)  # slot 1 = same redirect
        zf.writestr('inject.asb', inject_asb)
        for name in ('save0001.png', 'save0001_s.png', 'saveg.dat', 'system.dat'):
            zf.writestr(name, files[name])
        for name in ('inject.lua', 'inject.iet', 'http.lua', 'exploita.lua', 'proggy.ttf'):
            src = common / name
            if src.exists():
                zf.write(src, name)
        core = Path(__file__).resolve().parent.parent / 'seedsow_save' / 'core.lua'
        zf.write(core, 'core.lua')

    print(f'wrote {output_path} ({output_path.stat().st_size} bytes)')
    print()
    print('restore this zip with JKSV, then load save slot 1 in-game.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--backup', required=True, help='JKSV backup zip of the full game')
    parser.add_argument('--output', default='seedsow_fullgame.zip', help='output zip (default: seedsow_fullgame.zip)')
    args = parser.parse_args()
    build(args.backup, args.output)
