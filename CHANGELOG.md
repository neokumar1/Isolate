# Changelog

User-visible changes to Isolate, newest first. Release downloads are on [GitHub Releases](https://github.com/neokumar1/Isolate/releases).

## [1.3.0]

This is the first release since v1.2.7 and the first public build that includes the separation model; the v1.2.7 download did not contain it, so it could not separate songs. Your existing library carries over (see Library).

New since v1.2.7: three-band EQ on every stem and on the master bus, with presets and bypass; **Export Mix** (⇧⌘M) for the whole track as a 24-bit WAV; light and match-system themes; a peak limiter on the master output; folder import; and ⌥L to clear loop markers. The rest of this release is a broad hardening pass, listed below.

### Playback

- All five players (four stems and the original) now start on the same audio frame after play, seek, loop wrap, song changes and output-device changes. Previously stems could start 9–42 ms apart, and about one seek in five came out of sync. Starting also no longer stalls the window for about 50 ms, and the silence at each A–B loop wrap is down to roughly 30–40 ms.
- Selecting a song that has finished plays it again from the start (or from the loop start), keeping its mix.
- Pause and resume keep the stems aligned and resume instantly. Pausing, unloading a song and the end of a song (after 0.5 s) release the audio device.
- Seeking no longer plays a moment of audio from the old position through the speed and pitch processor.
- The shortest A–B loop is now 0.5 seconds rather than 2% of the song, so short phrases in long songs can be looped. Setting A after B, or B before A, starts a new loop instead of snapping back into the old one.
- Seeking to the end while looping jumps back to A. Releasing a scrub at the very end stops playback instead of restarting from 0:00.
- The loop controls are disabled until a song is loaded.
- Selecting the song that is already playing, or pressing Next or Previous with one song in the library, no longer resets its mix, loop, speed, pitch and position.
- A library entry whose files are missing no longer stops a different song that is playing.
- Importing a song now pauses the one that is playing.

### Separation & import

- Isolate now checks the separation model on a built-in test signal before using it. Core ML in macOS 14 and 15 computes the model incorrectly on some compute paths; Isolate picks one that passes, or asks you to update to macOS 26 instead of producing broken stems.

- Import whole folders by dragging them onto the window or choosing them with ⌘O. Files are added in Finder order, a file is never imported twice in one batch, and AIFC files are accepted.
- Batch imports show "N OF M" with the file name, can be cancelled as a whole, and end with one summary of the files that failed and why (the first three are named, the rest are counted).
- iCloud Drive files that are not on your Mac yet are downloaded first. If you are offline, Isolate says so instead of waiting.
- Surround files (up to 7.1) are downmixed to stereo by speaker position. Before, only their first two channels were used.
- Truncated or damaged WAV, FLAC and ALAC files are refused with how much of them could be read, instead of producing shortened stems.
- Isolate checks free disk space before separating and tells you how much it needs.
- Errors are in plain language: damaged or mislabelled files, an unusable model (with its location and the Core ML reason), and missing disk space.
- Cancelling while the model is loading now stops at once.
- New songs keep their Finder name: "AC/DC" no longer becomes "AC:DC", and a title such as "Song v1.2" keeps its version number.
- Reimporting a song removes the stems it replaced, and leftover temporary folders from an interrupted separation are cleaned up at launch.

### Library

- The library now has its own file at `~/Library/Application Support/Isolate/Library.store`. Earlier versions kept it in the shared `default.store`, which other apps can open and rewrite, emptying the library. On first launch, 1.3.0 copies your songs from a temporary copy of the old file; the old file itself is never changed or deleted.
- If the library file is damaged, it is moved into `Library Backups` with a timestamp, you are told where it went until you dismiss the notice, and a new library starts. It is never deleted. Other open failures leave the file untouched and retry at the next launch.
- Search matches the title, the file name and the folders shown in the sidebar (such as artist and album folders), but no longer the parts of the path every song shares, so common words don't match every song.
- Folder headers show enough of the path to tell folders with the same name apart.
- Next and Previous, from media keys or the menu bar, follow the sidebar's folder order.
- Songs cannot be deleted while a separation is running.
- Renamed titles are limited to 200 characters, and long titles no longer push the buttons out of the delete dialog.
- Now Playing and the menu bar keep titles that begin with numbers, such as "7-Eleven" and "99 Problems".

### Export

- 24-bit stem exports no longer clip. If any stem would go over full scale, all four are lowered by the same amount to −0.1 dBFS, which keeps their balance and their sum. Stems that don't need it are exported unchanged.
- Mix exports line up sample for sample with the source, and keep their full ending when speed or pitch is changed.
- Exports show their progress and can be cancelled from the EXPORT button, its menu or File › Cancel Export. A cancelled export leaves the destination untouched, and quitting mid-export no longer leaves partial files in the export folder.
- File names keep the library title's capitalization. Names that begin with dots are no longer hidden, characters that Windows cannot extract are replaced, and non-ASCII names in stem ZIPs extract correctly on Windows.
- The save panel says whether channel EQ is included. With Compare Original on, a mix export is named `_Original.wav` and says it contains the original recording.
- If the song changes while the save panel is open, nothing is exported and Isolate says why.
- Stem ZIPs are stored uncompressed, so the archiving step is quick.

### Interface & accessibility

- Red is reserved for active and interrupting states such as solo, mute, loop, play, clipping, export progress and errors. Resting controls are neutral, and Compare Original is amber.
- Text colors meet at least 4.5:1 contrast in both themes, and Increase Contrast is supported.
- The header, studio display and transport no longer truncate in smaller windows, and the seek bar stays usable down to the minimum window size. ⌘1 to ⌘5 hide the library when the display would not fit beside it.
- VoiceOver announces errors, and the mixer, EQ, macros, tabs, album art and BYPASS have labels, values and actions. The menu bar item reports whether Isolate is playing. Reduce Motion is respected.
- Escape closes About, Settings and the shortcut card without cancelling an import underneath.
- Settings › Shortcuts lists every shortcut and scrolls.
- Double-click resets work on pan controls, EQ knobs and EQ nodes. The pan readout rounds correctly, and keyboard steps land exactly on center.
- With all EQ bypassed (⌘E), every channel shows ALL EQ OFF; click it to turn EQ back on.
- Open Isolate in the menu bar reopens a closed window, and the window no longer opens as tabs.
- The menu bar icon follows the menu bar's appearance, so it no longer disappears when the app theme differs.
- Switches, tabs, steppers and the error toast's close button respond across their full area.

### Reliability

- Separating and exporting keep the Mac from idle-sleeping until they finish.
- Quitting during a separation or an export asks first. Quitting during a separation cleans up its temporary files before Isolate closes.
- Opening Isolate from the downloaded disk image offers to move it to Applications, including when macOS runs it from a temporary location. Replacing an installed copy asks first and moves the old copy to the Trash.
- Decoding artwork and reading a song's format no longer freeze the window on large images or sleeping network drives. Oversized artwork is skipped.
- The meters show the newest audio and short transients, and the stem meters go blank during Compare Original.
- Release builds include the separation model, are signed with the hardened runtime, and report 1.3.0 in About.

### Performance

- Separation reads each chunk of model output in one pass. The stems are bit-for-bit the same.
- Mix exports use the peak limiter's measured delay, so they stay sample-aligned with the source on every macOS version.
- Isolate releases the separation model after 60 seconds without a separation, and reloads it when needed.
- The meters and the player do less drawing work for each audio update, and Now Playing is no longer republished every second.

## Earlier versions

Notes for v1.2.7 and earlier are on the [Releases page](https://github.com/neokumar1/Isolate/releases).
