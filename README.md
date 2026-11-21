# Archive Downloader

A small Windows app for downloading files from [archive.org](https://archive.org) quickly, including files that require you to be logged in. It is a simple window around [aria2c](https://aria2.github.io/), a command-line downloader that uses several connections per file. That is usually much faster than downloading in the browser, because archive.org limits the speed of each connection.

## Files

| File | What it is |
| --- | --- |
| `ArchiveDownloader.cmd` | Double-click this to open the app. |
| `ArchiveDownloader.ps1` | The app itself (a PowerShell script). Keep it next to the `.cmd` file. |

## First-time setup

1. Double-click `ArchiveDownloader.cmd`.
2. If aria2c isn't installed, the window shows an **Install aria2** button. Click it. It installs aria2 through `winget` in a separate window.
3. When the install finishes, you're ready to download. You don't need to restart the app.

To install aria2 manually instead:

```powershell
winget install aria2.aria2
```

## Getting your archive.org cookie

Some files only download if you're logged in. The app proves you're logged in by sending your browser's archive.org cookie. You need two values: `logged-in-user` and `logged-in-sig`.

**Chrome or Edge**

1. Log in to archive.org and open any archive.org page.
2. Press **F12** to open DevTools.
3. Click the **Application** tab. If it's hidden, click **»** to find it.
4. In the left sidebar, under **Storage**, expand **Cookies** and click **https://archive.org**.
5. Type `logged-in` in the filter box.
6. Double-click the **Value** of `logged-in-user`, copy it, and paste it into the first cookie box in the app.
7. Do the same for `logged-in-sig` and paste it into the second box.

**Firefox:** the same steps, but the tab is called **Storage** instead of Application.

Notes:

- `logged-in-user` looks like your email address with `%40` in place of the `@`. Paste it as it is.
- `logged-in-sig` is a long, random-looking string. Copy all of it.
- You can also paste a whole cookie string (`logged-in-user=...; logged-in-sig=...`) into the first box and leave the second one empty.
- If you log out of archive.org, the cookie stops working. Log in again and copy fresh values.
- **Treat the cookie like a password.** Anyone who has it can use your archive.org account.

## Downloading

1. **Links:** add links to the list (see [The links list](#the-links-list) below).
   Use the direct file link, which looks like `https://archive.org/download/ITEM_ID/FILENAME`.
2. **Cookie:** fill in the two boxes. You can leave them empty for public files.
3. **Save to:** choose a folder with **Browse...**. It is created if it doesn't exist.
4. **Connections per file:** 8 is a good default. Try 16 if the download is slow.
5. **Files at once:** how many links download at the same time (default 5). The rest wait in a queue and start as earlier files finish. Set it to 1 to download one file after another, each at full speed. The total number of connections is roughly *files at once × connections per file*, so keep that sensible (archive.org may slow down or refuse very many connections).
6. Click **Download**. Links already marked **Done** are skipped.

A separate window opens with the progress of each file:

```
[#fb8bf8 57MiB/55GiB(0%) CN:8 DL:3.0MiB ETA:5h12m46s]
```

| Part | Meaning |
| --- | --- |
| `57MiB/55GiB (0%)` | Downloaded so far / total size |
| `CN:8` | Connections in use |
| `DL:3.0MiB` | Current speed (per second) |
| `ETA:5h12m46s` | Estimated time left |

When it finishes, the window says **All downloads finished** and waits for you to press Enter.

Each link is downloaded as its own file. You can close the main app window while downloads run, because the download window is independent.

### The links list

The list keeps its links between launches, so you can build up a queue and come back to it.

**Adding links**

- Type or paste a link into the box above the list and press **Enter** (or click **Add**).
- Pasting several lines at once (into the box, or with **Ctrl+V** on the list) adds them all.
- **Paste links** adds every link on the clipboard.
- **Load from file...** adds links from a `.txt` file (see below).
- Duplicate links are skipped.

**The Status column**

The app checks the save folder every few seconds and shows each link's status:

| Status | Meaning |
| --- | --- |
| **Done** (green) | The file is in the save folder and finished. |
| **Partial** (orange) | Downloading now, or stopped part-way (its `.aria2` file is there). Click **Download** to resume. |
| *(blank)* | Not downloaded yet. |

The status is worked out from the file name at the end of the link. If a site saves the file under a different name, the status stays blank. That doesn't stop it downloading.

**Removing links**

- **Remove finished** removes every link marked **Done**. This is the quick way to tidy up after a batch.
- **Remove selected** removes the highlighted links. You can also press **Delete**, or right-click and choose **Remove**. Click a link to select it, and use Ctrl+click or Shift+click for several. Ctrl+A selects all.
- **Clear all** empties the list after asking you to confirm.

Removing a link from the list never deletes a downloaded file.

Right-click a link for **Copy link** and **Open download folder** too.

### Load from file

**Load from file...** adds links from a `.txt` file to the list. Use one link per line. Blank lines are ignored, and lines starting with `#` are skipped, which is handy for notes or for leaving a link out:

```
# Concert recordings
https://archive.org/download/ITEM_ID/file1.flac
https://archive.org/download/ITEM_ID/file2.flac
#https://archive.org/download/ITEM_ID/skip-this-one.flac
```

## Stopping and resuming

Downloads can be resumed. If the window is closed, the PC sleeps, or the connection drops, open the app and click **Download** again with the same links and save folder. It continues where it stopped.

While a file is downloading, there's a `.aria2` file next to it. **Don't delete it**, because it's what lets the download resume. It disappears when the file is complete.

For long downloads, stop Windows from sleeping (Settings → System → Power), or just resume afterwards.

## Settings and where they're stored

Settings live in `%APPDATA%\ArchiveDownloader`. Click **Open settings folder** in the app to open it.

| File | Contents |
| --- | --- |
| `settings.json` | Save folder, connection count, files at once, the links in the list, the "Remember cookie" choice, and the cookie values. |
| `links.txt` | The links from the last download (aria2c reads this file). |

**About the saved cookie:** if **Remember cookie** is ticked, the cookie values are stored **encrypted** with Windows' built-in data protection (DPAPI), tied to your Windows account on this PC. That's why they appear as long hex strings in `settings.json`. They can't be decrypted on another PC or by another Windows user, so you'll need to paste the cookie again on a new machine. If **Remember cookie** is unticked, no cookie is saved.

To reset everything, including the saved cookie, delete the `%APPDATA%\ArchiveDownloader` folder.

## How it works

When you click **Download**, the app:

1. Writes the links that aren't **Done** yet to `links.txt` in the settings folder.
2. Opens a new PowerShell window that runs aria2c with:
   - `-i links.txt`: download each link as a separate file
   - `-d <folder>`: save to your chosen folder
   - `-j F`: download up to F files at the same time
   - `-x N -s N -k 1M`: use N connections per file, in pieces of at least 1 MB
   - `-c`: resume partial downloads
   - `--header "Cookie: ..."`: send your archive.org login
   - `--max-tries=10 --retry-wait=5`: retry if the connection drops
3. Passes the cookie to that window through an environment variable rather than the command line, so it doesn't show up in process lists.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| You get small HTML files instead of the real files | Your cookie has expired or is wrong. Log in to archive.org again and copy fresh values. |
| "aria2c was not found" | Click **Install aria2**, or run `winget install aria2.aria2`. |
| Slow speed | Raise **Connections per file** to 16, then click Download again (it resumes). If it's still slow, the limit is archive.org or your internet connection. |
| Downloads fail or crawl when many files are queued | Too many connections at once. Lower **Files at once** or **Connections per file**. |
| Download stopped with an error code | Click **Download** again to resume. |
| A borrowable (lending library) book won't download | Those are protected with DRM and can't be downloaded this way. |
