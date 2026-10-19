# Inkpage

The app was called SNotes until 2026-10-14. Its source folders, Xcode project and SwiftPM target
keep that name; what people see, the bundle (`Inkpage.app`, `com.krushock.inkpage`) and the data
folder are Inkpage. On first launch it takes over the old folder (`Application Support/SNotes`) and
settings (`com.snotes.app`); Keychain items keep their old service name, `com.snotes.app`, so macOS
may ask once whether Inkpage may use them.

A native macOS client for notes kept in Samsung Cloud by Samsung Notes, written from the sync
protocol as observed from the Windows client (`../protocol/sync-protocol.md`). Swift 6 toolchain,
Swift Package Manager, SwiftUI, macOS 26 or later. No third-party dependencies.

It is an independent client for the owner's own account. It is not made or endorsed by Samsung.

This is the developers' guide; the project's front page is `../README.md`. Where it points to
`../protocol/`, `../TODO.md`, `../AUDIT.md` or `../tools/capture`, those are working notes and research
tools kept privately: they are not part of the public repository.

## Layout

| Path | What it is |
|---|---|
| `Sources/SamsungNotesKit` | Everything without a window: sign-in, the sync service, the note format, drawing. |
| `Sources/SNotes` | The app: SwiftUI views over the library. |
| `Sources/snotes-probe` | Command-line companion for development. |
| `Tests/SamsungNotesKitTests` | Tests against sanitized real traffic in `Fixtures`, and a stub server. |
| `../tools/icon/make-icon.swift` | Draws the app icon. |

Inside the library:

| Folder | Contents |
|---|---|
| `Auth` | Samsung account web sign-in and its crypto, service tokens, Samsung Cloud registration, the account's secrets (Keychain). |
| `API` | The HTTP client (never follows a redirect by itself), multipart and gzip, the notes service. |
| `Model` | Folder tree nodes, change feed entries, the parsed note document, rich text. |
| `Ink` | Decoder for binary stroke records and the pressure-aware stroke renderer. |
| `Render` | Core Graphics and Core Text drawing of pages and card thumbnails. |
| `Sync` | The local store (`library.json`, one folder per note) and the two-way sync engine. |
| `Write` | Changing notes: the editable note document, the hash chain, text encoding, local edits. |

## Commands

```bash
./build.sh            # build
./build.sh test       # run all tests
./bundle.sh           # build/Inkpage.app, signed with the development identity when there is one
./xcode-build.sh      # the same app built by Xcode (Xcode/SNotes.xcodeproj): for CloudKit when the team allows it
```

The Xcode project compiles `Sources/SNotes` as the app and takes `SamsungNotesKit` from this
package; open `Xcode/SNotes.xcodeproj` to run and debug in Xcode (scheme "SNotes App").

Launch options are written `--name=value` (a bare path would be taken by AppKit for a document):

```bash
build/Inkpage.app/Contents/MacOS/Inkpage --store=<folder> --demo      # a library from a folder, no network, no Keychain
build/Inkpage.app/Contents/MacOS/Inkpage --store=<folder> --demo --window-snapshot=<out> [--dark] [--sign-in]
build/Inkpage.app/Contents/MacOS/Inkpage --store=<empty folder> --editor-check=<out> [--menu-only] [--dark]   # the scripted editor checks; report.txt in <out>
```

`snotes-probe import-capture <flows.jsonl> <folder>` builds such a library from a capture taken with
`../tools/capture`, and `snotes-probe render <folder> <out>` draws its notes to PNG.
`snotes-probe gate` builds a sign-in address and asks Samsung's gate whether it accepts it, without signing in.

The window snapshots are taken by the app of its own window; the display has to be awake
(`caffeinate -u -t 40 &`). Web content does not show in them while the app is in the background.

## What works, and how it was checked

| Part | Checked against |
|---|---|
| Sign-in request (`svcParam`) | The live gate answers with the same sign-in page address it gives the Windows client; the page renders in the app's web view. |
| Sign-in redirect decryption | A real redirect from the Windows client (unit test). |
| Master token, service token, cloud registration | Request shapes from the capture, replayed against a stub server (unit test). **Not yet run against the real servers.** |
| Folder and note change feeds, note download | Real answers as fixtures; the engine against a stub server. **Not yet run live.** |
| Stroke decoding and encoding | Five real strokes fill their stored bounds exactly and re-encode byte for byte; renders match the originals. |
| Hash chain | Recomputed for a phone-made and a Windows-made note. |
| Text encoding | Every text in the capture (14) reads into `NoteText` and writes back byte for byte, span list included; a new note has exactly the elements and attributes of a Windows one. Formatting values come from the client's code and have **not been seen by a Samsung client yet**. |
| Picture upload | The checksum matches the capture's three uploads; the file entry hash matches the three entries the Windows client wrote; the picture object's geometry matches the captured one digit for digit. Sequence against a stub server. **Not yet run live.** |
| Pens | Names, settings and the size law from the client's code; the fountain pen's level 30 gives the captured 6.007. Other pens **not yet seen by a Samsung client**. |
| Editor | `--editor-check`: 27 checks of what is stored after typing, formatting, undoing, pasting, drawing, moving and erasing with real events. |
| Text edits | 6,000 rounds of random typing, deleting, formatting and list changes: every result can be written, reads back the same and writes again as the same bytes. |
| Create, edit, draw, trash, restore, delete, folders | The engine against a stub server; the request sequence follows the capture. **Not yet run live.** |

## Samsung Cloud sync is experimental and unofficial

Samsung has not approved this app. Samsung Cloud sync talks to Samsung's servers the way
Samsung's Windows app does, which Samsung's terms forbid (reverse engineering, deciphering
transmissions to its servers). So it is turned on only after the person has read the risks and
ticked that they use it at their own risk (`SamsungRisks.swift`; the wording is
`TermsOfUse.samsungRisks`, versioned by `samsungRisksVersion`: a new wording is asked about
again, and sync already on is asked about at launch and turned off if it is not accepted). The
option says "Experimental" wherever it is offered, the sign-in sheet repeats it, and Settings
links the risks, the Terms of Use (`TERMS.md`) and the Privacy Policy (`PRIVACY.md`).

## Local first

The app needs no account. Notes, folders, drawing, pictures and import all work from the first
launch and are kept in `~/Library/Application Support/Inkpage/`. Sync is off until it is turned on
in Settings (Account & Sync): the switch asks for a Samsung account sign-in, and once signed in the
notes made here are sent and the ones in the account come down. Switching sync off again keeps
everything on the Mac and stops sending. Signing out removes the account and the notes that are
in the cloud from this Mac; notes that were never sent stay, and changes to a cloud note that were
not sent are kept as a separate "… (Mac copy)" note.

## The note editor

A note is shown as its pages, with the note's text in a text view laid over them (`RichTextEditor`).
The stored text (`NoteText`) is the truth: every edit in the view is applied to it and the view is
drawn from it, so text that was not touched goes back to the service byte for byte, whatever
attributes it carries. Formatting follows the encoding read from the Windows client's code
(`../protocol/sync-protocol.md` 5.13): bold, italic, underline, strikethrough, text colour,
highlight, size, checklists, bulleted and numbered lists, indent, alignment.

Drawing (`InkCanvas`, `NoteSession`): Samsung's own pens by name, setting and size law, shapes
(lines, arrows, rectangles and ellipses, saved as pen strokes), and undo and redo through the
window's undo manager. The tools down the side are the Windows client's, in its order, each with
its options in a panel beside the strip that opens when the tool in hand is pressed again
(`ToolStrip`, `ToolPanels.swift`; protocol 5.28 for how each option is stored):

- *Keyboard*: text size, bold, italic, underline, strikethrough, the 32 colours and any colour
  for the text, the seven and none behind it, checklist, bullets, numbers, left, centre, right,
  indent. (With the panel closed the same is in the bar at the foot of the window.)
  At its foot, *Text box*: a frame of text of its own, set down where the page is being looked
  at and written in at once. Press one to pick it, drag it to move it (to another page too),
  drag a handle to give it a size, double-click to write in it again; it grows downwards with
  its lines until it is given a size by hand, and one left empty is not kept. Stored as the
  Windows client stores its text boxes (an object of the page, protocol 5.29;
  `NoteTextBoxes.swift`, `TextBoxes.swift`). A box's text is all of one look: a box from
  another device that mixes looks takes its first letters' look when it is rewritten here.
- *Pen*: fountain pen, calligraphy pen, pen, pencil, brush, each remembering its own size and
  colour as the Windows client does; size 1 to 100; how see-through, for the pencil; for the pen
  and the pencil the four lines (even, thinning with the hand, dashed, dotted); Straighten lines;
  the palette with the colours last made, the dropper that takes a colour from the screen, and
  any colour; pens put by as favourites.
- *Highlighter*: highlighter and marker pen, with size, how see-through, Straighten lines and
  Adjust thickness to text (a stroke along a line of typed or PDF text covers that line).
- *Eraser*: stroke eraser, or area eraser with a size (a stroke it cuts through is left as the
  pieces on either side); only highlighter; only tape; Erase all handwriting.
- *Selection*: lasso or rectangle; with or without what is only partly inside.
- *Pointer* (this client's own, asked for; at the head of the strip, above the keyboard, which stays the tool a note opens with): a click on handwriting picks
  the whole block it belongs to (strokes nearer each other than a fortieth of the page's width),
  a press and drag moves that block at once, a drag over an empty place picks by a rectangle,
  a click on an empty place lets go. Text boxes and pictures are picked and moved by a click
  or a drag on them as well, and the rectangle picks them together with the handwriting: the
  lot then moves, resizes and is deleted together, and one Undo takes that back.
- *Tape*: a band in a colour or one of nine patterns that covers what is under it until it is
  pressed (with the tape tool or the keyboard); width, straight, fitted to text; the eye opens or
  closes every tape of the note. The patterns are drawn here after the Windows client's nine,
  not copied from its files.
- *Change style*: another size and colour for the handwriting that is picked.
- *Easy writing pad*: a strip at the foot of the note to write large in; each stroke is laid,
  as many times smaller as the box marked on the page is lower than the strip, into that box,
  which moves on when the writing passes the line near the strip's edge (or with the arrows,
  or to a new line with Return's key). A press on the page puts the box there; the two A's make
  the writing on the page smaller or larger.

Shapes and the Insert menu, which the Windows client keeps elsewhere, close the strip. The
palettes show the Windows client's colour sets that are ticked (four at first, of twenty-one;
the dotted button chooses). The strip is taken to the other side of the note by dragging the
grip at its head across (or its menu).

**Apple Intelligence** (`NoteIntelligence.swift`, `MathNotes` in the library), after Apple's
Notes, with the Mac's own language model (the FoundationModels framework; nothing leaves the
Mac, and without Apple Intelligence these are simply not offered):

- *Calculations*: a calculation typed with its "=" is answered where it stands, in the colour
  of results, and the answer follows when the calculation is changed: `10+5=` gives 15. Signs,
  brackets, powers, per cent, the usual functions, and names given a value on an earlier line
  (`width = 12`, then `width * 3=`). The arithmetic is always done by the app itself, exactly.
  A calculation in words (`15% of 240=`, `3 feet in cm=`) is first put into arithmetic by the
  language model, and then worked out the same way. What is typed after an answer is ordinary
  text. The answers are ordinary coloured text in the note, so every client shows them.
- *Write with AI*: the button in the note's toolbar (also Edit › Write with AI…, ⇧⌘J); it
  asks what to write, shows the text as the model writes it, takes a request to
  change it, and puts it into the note at the caret as one step that Undo takes back.
- *Writing Tools*: the system's own (proofread, rewrite, summarise) work on text picked in a
  note, from the Edit menu or a right click.

Both can be switched off in Settings › General. A change shows at once from memory;
writing happens off the main thread, in order, and only the page that changed is drawn again.

Pictures: paste, drop or insert; set in the text as the Windows client does it, or placed freely
on a page when dropped while drawing. Press a picture anywhere to pick it and move it at once; eight
handles resize it (corners keep its proportions), a red button deletes it, and Delete removes it
when it is picked. A picture set in the text moves between paragraphs and to the left, middle or
right of the column (its paragraph's alignment); a free picture moves anywhere on any page. The
round handle above a picked picture turns it about its middle: it settles on quarter turns, and
with Shift held it goes in steps of 15 degrees. A turned picture in the text gets the room of its
turned outline. The angle is stored as `rotationDegree` on the object; no Samsung client has yet
been shown a picture turned here. Files are uploaded before their note (`createUploadURLs`,
signed `PUT`), with the checksum and the file entry's hash as the Windows client computes them.

Pages can be added, removed and reordered (in the bar at the side, see below); their paper is set in Note style. PDF, picture and text files can be imported
as notes; notes go out as PDF, pictures or text. Handwriting is read with Vision in the background
so that search finds it. Locked notes open after Touch ID or the Mac's password.

`--editor-check=<folder>` (with `--store=<a copy of a library> --demo`) runs the editor through
typing, formatting, undo and redo, a pasted picture, four pens, shapes, selection and the eraser
with real events, saves pictures of each step and a `report.txt` of what was stored.

## Picture menu, note style, inserts and finding (2026-10-12)

A right click on a picture gives the menu of the original: Cut, Copy, Paste, Delete, Crop, Lasso
Crop, Remove Anchor to Text (or Anchor to Text), Fit to Page Width, Share (the system's share
menu) and Save Image (the system's save panel). Over a picture the pointer is a hand, a closed
hand while it is dragged, resize arrows over a handle.

- **Crop** shows the whole picture again, faded outside the part kept; corners and sides are
  dragged, the kept part itself can be moved, Return or a press beside the picture keeps it,
  Escape leaves it. A double click on a picture starts it. The file is never cut: the note
  keeps the part shown (`cropRect`, in pixels of the file) and the frame the whole picture would
  have (`imageOriginalRect`), as Samsung's clients do, so the crop can always be changed or taken
  off ("Show Whole Picture").
- **Lasso Crop**: a loop drawn on the picture cuts it out. As the clients keep it: a copy that is
  clear outside the loop becomes the picture shown, the first picture stays in the note as its
  original (`originalImageId`), and the loop's box is an ordinary crop.
- **Anchor**: a picture set in the text is freed to lie on its page, a free one set into the text
  at the paragraph it lies over.

**Pages** are down the side of the note's window (the button beside Find), as in the original
and in Preview: press one to go to it, drag one to another place, add after any page or at the
end, delete with the bin, the page's menu or the Delete key. A page that holds ink or a picture
is asked about first, because deleting it cannot be undone. Opening a note closes the folders at
the side of the main window; they come back with the list of notes.

**Note style** (the palette button): the paper's colour for the whole note (the original's
eighteen), a ruling for all pages or the one being looked at (lines, squares and dots in three
widths, to-do, ruled with margin, week, month, music paper: `templateType`, drawn here with
the measures Samsung's engine draws its own with, never stored as pictures), or a picture or PDF
page of one's own under the
page (`templateType` 12 with `bgImageId`). A plain page turns dark in the dark look; a coloured
one keeps its colour, and writing on a dark colour is shown light. The scroll direction (down the
pages, a page at a time, two pages side by side) is how this Mac shows the note, kept in the
app's settings per note: Samsung's clients do not keep it in the note either.

Text is set 1.35 times its size from line to line, the measure the rulings are made to: text of
size 12 sits on the narrow lines, 17 on the medium, 28 on the wide, as in a ruled notebook.
`snotes-probe templates <out.png>` draws every ruling on a page for a look.

**Insert** (the plus in the tools): Image, PDF (each page becomes a page of the note that shows
its page of the document, see Import PDF below), Drawing (a sheet to draw on; the result is a picture), Voice Recording
and Audio File (kept as `voiceData` with an m4a or the file as it is; played from a row above
the pages), Sticky Note and Table.

Sticky notes and tables are **Samsung's own kinds**, which Galaxy devices and Windows show and
edit like their own:

- A **table** is an object of type `tableNew` with its rows, columns and cells in a binary record
  (`SamsungTable`), set in the text by a place of its own. A new one asks for its rows and columns
  on two wheels. A double click opens it where it stands, as the Windows client shows one: the
  cells are typed into; a grip above each column's edge drags the column wider or narrower; a
  handle above the caret's column and one beside its row pick the column or row, and picked,
  open its menu (cut, copy, paste, fit to the page's width, add, delete, cell style, table
  style). Cell style gives the picked cells a paper, a text size, bold, italic, underline,
  strikethrough, a text colour and an alignment; table style does the same for every cell, and
  sets a heading row, a heading column and one of the five kinds of lines. Rows grow with the
  lines of their text; the text below makes way. Everything read from a table is kept and
  written back as it was, so a table changed on any device stays editable here.
- A **sticky note** is a small folded square on its page (a `customObject` of the page). One
  click opens it into a note of its own, where it is written on, given another paper, deleted or
  folded up again (Esc); it is dragged about by its square. What it says is kept in a small note
  document of its own, an `.sdocx` among the note's files (`StickyDocument`).

Both forms were worked out from two test notes made in the Windows client and are checked against
them byte for byte: the Windows table records and the Windows sticky note's file are read and
written back identically. Text that another client formatted in parts (a bold word in a cell, a
larger line on a sticky note) keeps its formatting: the text's own record is kept, and when the
words change every character that stays keeps its style and a new one takes the style of the one
before it. A cell is made bold or italic as a whole from the bar shown while the table is open
(the cell the caret is in). A sticky note's paper is one of the four the Windows client offers
(yellow, green, red, blue). What is written in a table or on a sticky note is undone and redone
with the note's Undo. A table or sticky note that holds something this client does not write
(merged cells, borders of its own, handwriting on a sticky note) is recognised by not coming out
identical, and is then shown and not changed. Tables and sticky notes that an earlier build of
this app kept as pictures become Samsung's own, in the same place and saying the same, when they
are opened.

**Settings** follow the Windows client's: sync and account; General, with the default note style
(a new note's page style, split pages or one page that grows; its layout, normal or long 1:2; its
paper colour, ruling and scroll direction), the password for locked notes, and Auto save notes
(off: what is typed is stored on ⌘S or when the note is left); appearance; and a privacy notice
of this app's own.

**What the notes are synced with** is chosen from a menu in Settings › Account & Sync: nothing,
Samsung Cloud, iCloud Drive, or (in a build registered with Google) Google Drive, one at a time. Changing it asks what should become of the notes the
service being left holds: keep them on this Mac (they then go to the new service too) or take
them off this Mac (they stay where they are, and notes that were never sent, or were changed
since, stay here).

*iCloud Drive* is a folder, `Inkpage` (or `SNotes`, where one was made under the old name), in the user's iCloud Drive, which every Mac running this app
shares (`FolderSync`). The app has no entitlement for CloudKit, so it does not use Apple's
database: it keeps files that iCloud Drive carries. Each note is a file that is never changed
once written (`notes/<id>/<number>-<device>.snote`: the note's document and strokes, zipped) with
its attached files beside it under their content hashes, each written once; folders and the
notes' places among them are one small file each under `tree/`, the newer of two holding. A Mac
that changes a note writes a new file naming the one it replaces and removes that one, so two Macs
never write over each other. A note changed on two Macs before they synced is left alone on both
and shown as "changed in two places"; the user keeps this Mac's, the other's, or both as two
notes. A note is deleted for the others only when it was deleted for good here: one that is
merely missing from a Mac comes back.

*CloudKit.* The Xcode project (`Xcode/SNotes.xcodeproj`, built by `./xcode-build.sh`) signs the
app with the iCloud capability when the signing team may have it, and the app then syncs through
CloudKit instead of iCloud Drive: the user's private database of the container
`iCloud.<bundle id>`, a zone `Notes`, and in it one record of type `File` for every file of the
same folder, the file as the record's asset (`CloudKitFiles`). A copy of that folder lies on the
Mac (`<store>/cloud`); each round brings the database's changes into the copy, lets `FolderSync`
bring the copy and the notes to the same state, and sends what changed in the copy
(`CloudMirror`). Versions, conflicts, deletions and encryption are therefore the same code as for
iCloud Drive. In such a build the key of encrypted notes is kept in the keychain that iCloud
syncs, and no password is asked for. Apple gives the iCloud capability only to teams of the paid
Apple Developer Program: with a "Personal Team" the project is built without it (the script says
so and why), and the app syncs through iCloud Drive as described above.

*Google Drive* is reached through Google's own interface (Drive v3) with the permission of a
Google account, not through a folder that some app of Google's keeps in step. The app asks for
one scope only, `drive.appdata`: its own hidden folder of the Drive, which no other app and not
the user's Drive window can see into, and nothing else in the Drive. The files there are those
of the sync folder described above, each a Drive file whose name is its path
(`GoogleDriveFiles`), and the rounds are `CloudMirror`'s, with this Mac's copy in
`<store>/google`: so versions, conflicts, deletions and encryption are again the same code. Drive
has no paths and allows two files of one name, so each round lists the folder whole (one request
for every thousand files) and compares the list with the last one; of two files of a name the
newer holds and the other is removed.

Signing in (`GoogleAccount`) is Google's own page in the system's sign-in window
(`ASWebAuthenticationSession`, which shares the browser's session, so an account signed in there
is offered): choosing Google Drive opens it, and Google's answer comes straight back to the app
at an address made of the app's client ID, to be redeemed with PKCE. No secret is involved, and
there is nothing to type into the app. The lasting token Google hands out is kept in the Mac's
keychain.

Google shows its page only to an app registered with it, under a client ID that is built into
the app, as with every app that signs in with Google. This is done once by whoever builds the
app, in Google Cloud Console: a project with the Google Drive API enabled; the consent screen
(audience External; published, or with the users listed as test users); and an OAuth client of
the application type "iOS" (Google's name for an app of Apple's platforms) with the bundle ID
`com.krushock.inkpage`. Its client ID goes into `GoogleRegistration.clientID` in
`Sources/SNotes/GoogleSignIn.swift` (or, to try one without building,
`defaults write com.krushock.inkpage GoogleClientID <id>`). A build without one does not offer Google
Drive in Settings (`../TODO.md` has the steps). The hidden folder belongs to the client's project: every Mac must run a build
with the same client ID and sign in to the same Google account.

*Encrypting locked notes* (iCloud and Google Drive): a 256-bit key made on the Mac seals each locked
note, its attached files and its title with ChaCha20-Poly1305 before they are written to the
folder. The key lives in the Mac's keychain; beside the notes lies only a copy of it locked with a
password of the user's choosing (PBKDF2-HMAC-SHA256, 310,000 rounds), which is typed once on each
other Mac. (iCloud Keychain would have carried the key without a password, but an app needs an
entitlement for it that this one, built outside Xcode's provisioning, does not have.) The notes on
the Mac itself are not encrypted.

**Locked notes.** Samsung's lock does not encrypt a note: the service delivers it like any other,
marked as locked, and each client asks who is there before showing it. Samsung's clients ask for
the account's notes password; this app asks for Touch ID, which falls back to the Mac's password.
A note is locked and unlocked from its toolbar, the Note menu or a right click on its card (after
Touch ID), marked as the Windows client marks it, so it is locked on every device. The notes
password itself, which the other devices ask for, can be changed in Settings › General once the
current one has been typed there; it is sent with the next sync.

**Find** (⌘F, or the magnifier): marks every place the note's text holds what is typed, whatever
its case and accents, and steps through them; in a note shown a page at a time it turns to the page.

Checked by `--editor-check` (91 checks of these alone, also on their own with `--menu-only`):
the pointer's shapes, the menu's items, copy and paste, fit, freeing and anchoring, finding, pages
added and deleted, a crop by real drags and what is stored for it, a loop and what is stored for
it, undo of both, a sticky note opened by a click and a table written in place and read back from
what is stored, a recording from a
sound file, a PDF of two pages, colours, rulings, a paper of one's own, and the three scroll modes.

## Import PDF

"Import PDF" (beside Create note, and File › Import PDF…, ⌥⌘I; a PDF dropped on the notes or
chosen with Import… goes the same way) makes a note of a PDF as Samsung's clients do, so that it
is the same note on every device: the note is named after the file and has one page for every
page of the document, as wide as the note's pages and as high as keeps the document page's shape,
then the usual empty spare page. Each page names the document, which is kept whole as a file of
the note, and its page in it (`pdfDataList`, protocol 5.18); the page is drawn from the document
itself, sharp at any zoom, under whatever is written or drawn on it. Insert › PDF adds such pages
to a note that is open (an empty note gives them its place). A page of a PDF keeps its own white
paper in the dark look, and the note's card shows the top of the first page. The PDF is not
converted: it is the paper under the page, there to be written and drawn on, and a note made of
one opens with the pen in hand. With the keyboard the pointer over it is an arrow where the note
has no text of its own. The PDF's text can still be had, which Samsung's clients do not offer:
with the keyboard tool, hold ⌥ and drag over it to pick it as in Preview (two presses with ⌥
pick a word, three a line; the pages scroll on when the pointer is held at the window's edge),
then ⌘C or a right click copies. Nothing of that is stored in the note. Pages of one note
may now be of different heights (`NoteLayout.height(_:)`, `top(_:)`): the editor, the pages at
the side and Export as PDF follow each page's own. Taking the last page of a PDF out of a note
takes the document out of it.

## Pages and the text

The note's text is set page by page, in the library (`TextFlow`, for what is stored, exported and
printed) and in the editor (`PagedTextContainer`) alike: a line, or a picture set in the text, that
does not fit in what is left of a page starts the next page, below that page's top margin. Nothing
lies across the break between two pages. A picture is never given more room than a page has.

## The spare page

Samsung's clients end every note with an empty spare page and do not show it (`protocol/sync-protocol.md`
5.16). This app keeps that page in the file, as they write it, and leaves it off the screen, in export
and in print, while it can be shown to be empty. `NoteLayout.shownPageCount` decides, and it is
built so that nothing is ever hidden that someone put there: a page is left off only if it has no
objects of any kind (also kinds this app cannot draw), no recorded drawn area, nothing placed
above it reaches down onto it, the note's text does not reach it, and it is a bare page that
looks like the one before it. A page with an attribute or part this app does not know is always
shown. Empty pages between pages that hold something are shown. "Add Page" shows an empty page
the note already keeps before it adds a new one. The tests that guard this are in
`PageVisibilityTests`, including random notes in which nothing that holds something may be hidden.

## What it does not do yet

- Nothing after the sign-in page has run against Samsung's servers. Everything below "works" in
  the sense of the tests and the stub server; the first live run decides.
- Locked notes: on this Mac the lock is the Mac's own login (Touch ID or its password), not the
  Samsung notes password. A forgotten notes password is reset
  in a Samsung app (it checks the Samsung account), not here; the first password of an account is
  best made there too. Locking, unlocking and changing the password have not been tried against
  the service yet. End-to-end encrypted notes are skipped.
- CloudKit has never run: the developer team at hand is a Personal Team, which Apple does not
  let use iCloud (`xcodebuild` says so). The code that talks to CloudKit is compiled and its
  logic is tested against a stand-in cloud kept in memory; the calls to Apple's servers
  themselves are untried, and so is the keychain that iCloud syncs.
- Syncing through iCloud Drive has been tried against an ordinary folder standing in for iCloud
  Drive, with a second library playing a second Mac, never yet against iCloud Drive itself or
  between two real Macs: files that iCloud has announced but not downloaded, and its own
  permission prompt for the folder, are handled by the book and untested. It is for Macs running
  this app; nothing on an iPhone or in Samsung Notes reads that folder. A forgotten encryption
  password cannot be reset: with no Mac left that holds the key, the encrypted copies are lost.
- Google Drive has never run against Google: no client ID is built in yet, and making one is
  for the owner of a Google account. Everything else has run: the sign-in window, the answer
  coming back to the app, the tokens and Drive's interface, against a stand-in for Google on
  this Mac that answers over HTTP as Google's documentation says (`Tools/fake-google.py`; run
  it, then `--editor-check=<out> --sync-only --google-test-server=http://127.0.0.1:<port>`).
  What only Google can show: its consent page, its limits on how fast a Drive is written to,
  and whether it sends a file's content from another of its hosts. A client left "in testing"
  in Cloud Console gets tokens that last a week, after which the app asks to sign in again:
  publishing the app there (no review is needed for this scope) ends that. As with iCloud, it
  is for Macs running this app.
- A new note laid out on its side (Landscape) cannot be made here: no such note has been seen,
  and one of its attributes is a guess. Notes of that kind from other devices are shown with
  their text at the right size. "Restore" from a `.sbak` backup is not here.
- `.sdocx` files are read and written only for sticky notes (a note with one page and plain
  text); a whole note cannot be exported to or imported from an `.sdocx`.
- The tools: no stroke with the new options (the marker pen, Pencil2, an even, dashed or dotted
  line, a tape) has been opened in a Samsung client yet; their storage is read from the Windows
  client's code, and for the tape partly inferred (`../TODO.md` lists the Windows samples that
  would settle it). The area eraser's sizes are this client's own (Samsung's reach per size is
  not known). The Easy writing pad lays strokes down as the Windows client's is described to;
  how exactly that one scales and steps has not been measured.
- A PDF made a note of on this Mac has not been opened in a Samsung client yet, and the note
  the Windows client made of a PDF has been read from that client's own store, not yet as the
  service passes it on (`../TODO.md`). In a note whose pages differ in height the typed text
  is set page by page at each page's own height; that is tested in the library, and has not
  been looked at in the editor with such a note.
- Shapes are saved as pen strokes, not as Samsung's shape objects; formulas in notes from
  other devices are shown where they can be and not edited. Text boxes are written as the
  Windows client's code writes them and have not been opened in a Samsung client yet; a text
  box is not turned here, and one that is turned in a note from another device is drawn upright.
- In a table opened here the cells are typed into as plain text: formatting of part of a cell's
  text is kept and drawn when the table is closed, and styles are set for whole cells. A row's
  height follows its text; the handle the Windows client shows for dragging a row taller is not
  here (what it stores is not known). A table with merged cells is shown and not changed (the
  Windows client cannot make one). Handwriting on a sticky note makes it read-only here.
- A table's heading, papers, lines and cell styles are written as the Windows client's code
  writes them, but none of those has been seen in a note of that client yet. (The Windows client has no
  way to merge cells; the table record only has the fields for it.)
- The green, red and blue sticky papers are the Windows client's colour constants nearest to a
  screenshot of its picker; only the yellow was read from a note.
- What a Samsung client makes of a table or a sticky note written on the Mac has not been seen
  yet: the bytes are in the form of that client's own, but the round trip needs a sync and a look
  at the other device.
- What Samsung's clients make of things written here in forms taken from their code and not yet
  seen in a note of theirs: a crop, a cut-out, a ruling, a paper of one's own, a recording, a
  turned picture. The forms are in `protocol/sync-protocol.md`, each marked as confirmed in
  the code or inferred.
- Recording from the microphone has not been run by the scripted checks (the system asks a person
  for the microphone); keeping and playing a sound file has.
- Undo takes back a change of paper, an added, deleted or moved page and an inserted PDF by
  putting the note back whole as it stood before (`NoteSnapshot`); steps of drawing made before
  a page was added or removed are forgotten at that point, as before.
- Font family is kept and shown when the Mac has the font, and cannot be chosen. Links are
  recognised for display and left for Samsung's clients to mark in the note.
- Notes with more than about 95,000 strokes refuse more ink: Samsung's clients group strokes past
  100,000 in a record this client does not write.
- Conflicts: when a note changed both here and elsewhere, or was deleted elsewhere with changes
  here unsent, the other device wins and the note as it was on this Mac (text, handwriting,
  pictures) is kept as a new note named "… (Mac copy)". Text typed into a note while another
  device's version arrives goes into such a copy too. There is no merging.

## How edits and sync stay out of each other's way

- Every change made in the app goes through `LocalEdits`, which rewrites the note's files and its
  library record inside `LocalStore.exclusive`, raises the record's `revision`, and marks it `pending`.
- The sync engine reads what it uploads (record and files together) and writes what it downloads
  inside the same exclusive section, never across a network call.
- An upload clears `pending` only if the record's `revision` is still the one that was read.
- The change feed's cursor always advances; notes whose download failed are kept on a retry list.

## Where things are kept

- Notes: `~/Library/Application Support/Inkpage/` (`library.json`, `notes/<id>/note.xml`, `strokes/`, `media/`, thumbnails).
- Account tokens: one item in the login Keychain (service `com.snotes.app`).
- `sync.log` in the same folder lists requests and status codes, without tokens or content.
- Signing out removes from this Mac the notes that are in Samsung Cloud and the account's tokens.
  Notes that were never sent stay, and so do changes that were not sent (as "… (Mac copy)" notes).
