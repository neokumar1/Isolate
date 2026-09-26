# Troubleshooting

## macOS won't open Isolate

Releases are ad-hoc signed and not notarized, so macOS blocks the first launch until you approve it. Follow [First launch](README.md#first-launch) in the README:

- **macOS 15 and later:** open Isolate once and click **Done**, then go to **System Settings › Privacy & Security**, click **Open Anyway** next to the Isolate message, authenticate, and click **Open**. If Open Anyway is not shown, open Isolate again and go straight back to that page; the button only appears for a while after a blocked launch. If your account can't approve it, ask an administrator of the Mac.
- **macOS 14:** Control-click Isolate in Applications, choose **Open**, then click **Open**.

If macOS says Isolate **is damaged and can't be opened**, the download is incomplete or was changed after it was signed. Delete it, download `Isolate.dmg` again, and compare `shasum -a 256 Isolate.dmg` with the release's `SHA256SUMS.txt`.

Don't turn off Gatekeeper or run `xattr -cr` on the app. Those skip the check for more than Isolate and hide real problems with a download.

## macOS asks to access Downloads, Documents, Desktop or a drive

Isolate leaves imported songs where they are. When you select a song later, it rereads the original for its artwork and tags, and to rebuild stems that are missing, so macOS asks for access to the folder or drive it is in. Allow it. If you deny it, stems that were already separated still play, but the artwork and tags may be missing and missing stems can't be rebuilt. You can change the choice in **System Settings › Privacy & Security › Files and Folders**. Because releases are ad-hoc signed, macOS may ask again after you update Isolate.

## Import says the model is missing or can't be loaded

- **"CoreML Model Not Found"** means this copy of Isolate has no separation model. The v1.2.x downloads and source builds don't include one. Install the current release from [Releases](https://github.com/neokumar1/Isolate/releases/latest), or follow [MODEL.md](MODEL.md) for a source build.
- **"Model Could Not Be Loaded"** names the model it tried and the reason Core ML gave. If the path is inside `Isolate.app`, reinstall the app. If it is `~/Library/Application Support/Isolate/HTDemucs.mlmodelc`, replace that folder with the validated model from [MODEL.md](MODEL.md) and check it with `scripts/validate_model.swift`.

Isolate never downloads a model by itself.

## A file won't import

Isolate imports MP3, WAV, FLAC, M4A (AAC or ALAC), AIFF, AIFC and CAF files through macOS's own decoders. It can't import DRM-protected files such as Apple Music downloads, OGG or Opus, or files with more than 8 channels. Renaming a file's extension does not convert it.

- **"The file is damaged, or its contents do not match its extension"** or **"The file could not be decoded"**: try playing the file in Music or QuickTime Player. If it doesn't play there either, export or download it again.
- **"The file appears damaged or incomplete: only 2:10 of 4:05 could be decoded"**: a WAV, FLAC or ALAC file is shorter than its header says, usually from an interrupted copy or download. Get a complete copy.

When several files fail in one batch, the message at the end names each file and its reason.

## Files in iCloud Drive

If a song is in iCloud Drive but not downloaded to your Mac, Isolate asks macOS to download it and shows **DOWNLOADING FROM ICLOUD...** until it arrives. There is no percentage because macOS doesn't report one. If your Mac is offline, the import stops with a message saying the file hasn't been downloaded. To avoid the wait, choose **Download Now** on the files in Finder before importing.

## Not enough disk space

Before separating, Isolate checks the free space on the disk that holds its library and stops with "Not enough disk space: separating this track needs about … free, and … is available." Each separated song keeps about 106 MB per minute of audio. Free up space, or delete songs you no longer need from the library, which removes their stems.

Exporting stems also needs temporary space for four 32-bit copies of the stems plus the finished files. If a disk fills up during a separation or export, the error shown comes from macOS.

## An import looks stuck or slow

- **LOADING SEPARATION MODEL...** takes longer the first time after you install or update Isolate, while macOS prepares the model for your Mac. On the test Mac that took about 17 seconds; later loads took 3 to 4 seconds.
- **DOWNLOADING FROM ICLOUD...** waits for iCloud; see above.
- **SEPARATING STEMS...** advances one chunk (5 seconds of audio) at a time. The time remaining and speed are measured from the chunks already finished, and speed depends on your Mac and what else is running.
- **CANCELLING...** waits for the chunk in progress to finish, then removes the unfinished files.

If a separation really stops moving, quit Isolate. It asks first, cancels the import and removes its temporary files. Anything left behind by a crash is cleaned up the next time Isolate starts.

## The library is empty or was moved to Library Backups

The library is `~/Library/Application Support/Isolate/Library.store`.

- **After updating from a version before 1.3:** on its first launch, 1.3 copies your songs from a temporary copy of the old shared `~/Library/Application Support/default.store`. If that fails, Isolate says so and leaves the old file unchanged.
- **"Isolate could not open its library and started a new one":** the old library files were moved, not deleted, into `~/Library/Application Support/Isolate/Library Backups/<date and time>/`, and the message gives the exact folder.

To restore a backup, quit Isolate, move `Library.store`, `Library.store-wal` and `Library.store-shm` out of `~/Library/Application Support/Isolate`, copy the files from the backup folder in their place, and open Isolate. If it still can't be opened, the backup may have been written by a newer version of Isolate; install that version and try again.

Your separated stems stay in the `Stems` folder either way. Importing the same original files again finds their stems by content and reuses them without separating again.

## Stems are missing or the original was moved

When a song's stems are missing or damaged, Isolate rebuilds them from the original file. If the original has moved too, you'll see **AUDIO SOURCE NOT FOUND**; import the file from its new location. Songs whose stems are complete keep playing without the original, but their artwork and tags may be unavailable.

## Exported stems are quieter than the player

Separated stems can peak above full scale; on test songs they reached 1.3 to 1.5 times full scale, and EQ boosts can add more. 24-bit WAV and FLAC can't store that, so when any stem would clip, Isolate lowers all four stems by the same amount until the loudest peak is at −0.1 dBFS. The stems keep their balance and still add up to the mix, just at a lower level. To match the player, raise all four by the same amount in your editor. Stems that don't need it are exported unchanged. Mix exports go through a peak limiter instead.

## No sound

Check the Mac's output device and volume, then Isolate's play state, faders, mute and solo buttons (R resets them), and whether Compare Original (BYPASS) is on. Playback from a stop starts a fraction of a second after you press play so all four stems start together. When you change output devices, Isolate restarts playback at the same position; if the new device is still connecting, pause and play again. Bluetooth devices add their own delay.

## Export fails

Check free space on the destination and on your startup disk, and that you can write to the destination folder. An existing file is replaced only after the new export is complete, and a cancelled or failed export leaves it untouched. If you see "The track changed while the save panel was open. Nothing was exported.", another song loaded, for example from a media key, while the save panel was open; export again. Isolate does not export MP3.

## The window is gone

Isolate can keep playing with its window closed. Choose **Window › Show Isolate** (⌘0), or **Open Isolate** from the menu bar icon.

## Reporting a problem

Open an issue at <https://github.com/neokumar1/Isolate/issues> with the Isolate version (shown in About), the macOS version, your Mac model, the audio format, sample rate and length, the steps you took, and the exact message. Please don't attach copyrighted or private audio; a short clip you're free to share, or a description of the file, is enough.

## "This version of macOS computes the separation model incorrectly"

Core ML in macOS 14 and 15 produces wrong output from Isolate's separation model on some compute paths. Isolate tests the model before every separation session and uses a path that passes; this message means none did on your Mac, so Isolate refused rather than create broken stems. Update to macOS 26 or later (every Apple silicon Mac can run it) and import the song again. Songs you already separated keep playing and exporting normally.
