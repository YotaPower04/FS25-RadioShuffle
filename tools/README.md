# Radio Shuffle — Music Audio Leveler (optional)

These scripts even out the **loudness** of the `.mp3` files in your Farming
Simulator radio music folder, so loud and quiet songs play at a consistent
volume. **The game never runs them** — they're here only if you want them.

- Windows: `normalize_music.ps1`
- Linux / macOS: `normalize_music.sh`

They use **ffmpeg** (EBU R128 two-pass `loudnorm`, linear gain). If ffmpeg
isn't installed, the script downloads a small portable build into `tools/bin/`
automatically (no admin rights) and verifies it against the provider's checksum.
Your **original files are backed up** to a `music_backup/` folder next to your
music before anything is changed.

## What it touches
Your FS25 music folder, e.g.:
`…/My Games/FarmingSimulator2025/music/`
(the same folder your custom radio plays from).

## Just want to click it?
Run the script with **no arguments** (double-click → *Run in Terminal* on Linux,
or right-click → *Run with PowerShell* on Windows) and you'll get a menu:
```
  1) Dry run      (show each song's loudness, change nothing)
  2) Level audio  (normalize to -16 LUFS; originals backed up)
  3) Undo         (restore your original files)
  4) Quit
```
The window stays open at the end so you can read the result. Power users can
still pass flags instead (see below) to skip the menu.

## Usage

### Windows
Open PowerShell in this `tools` folder and run:
```powershell
powershell -ExecutionPolicy Bypass -File .\normalize_music.ps1
```
If it can't find your music folder automatically, pass it:
```powershell
powershell -ExecutionPolicy Bypass -File .\normalize_music.ps1 "C:\Users\YOU\Documents\My Games\FarmingSimulator2025\music"
```

### Linux / macOS
```bash
chmod +x normalize_music.sh
./normalize_music.sh
# or pass the folder:
./normalize_music.sh "$HOME/.../FarmingSimulator2025/music"
```

## Options
| Option | Meaning |
|---|---|
| `--target N` (`-Target N`) | Target loudness in LUFS (default **-16**). -14 = louder, -18 = quieter/safer. |
| `--dry-run` (`-DryRun`) | Show what would happen; change nothing. |
| `--no-backup` (`-NoBackup`) | Don't copy originals first (not recommended). |
| `--undo` (`-Undo`) | Restore your original files from `music_backup/`. |
| `--jobs N` (`-Jobs N`) | Parallel files at once (Linux/macOS; default 2). |

## Tips
- Run `--dry-run` first to see your songs' current loudness.
- After it finishes, **reload your FS25 save** to hear the result.
- Re-running only processes **new or changed** songs (it remembers what it did).
- Made a mistake or don't like it? `--undo` puts your originals back.

## Notes
- First run without ffmpeg installed needs an internet connection (to fetch the
  portable build). After that it's offline.
- Re-encoding mp3 is a (small) quality step; that's why originals are backed up.
  If you'd rather it be lossless, install **mp3gain** and normalize with that
  instead — but ffmpeg here is the no-setup, cross-platform option.
- `bin/`, `.state/`, and `music_backup/` are created when you run it; they aren't
  part of the mod and the game ignores them.
