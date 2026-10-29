# Third-party notices

Inkpage contains no third-party source code and has no package dependencies
(`app/Package.swift` lists none). What it uses from others:

## Apple frameworks

The app is built with Apple's SDK and uses the frameworks of macOS (among them SwiftUI,
AppKit, PDFKit, Vision, CryptoKit, WebKit, AuthenticationServices, AVFoundation and
FoundationModels). They are part of macOS and are not included in this repository; they
are used under the Xcode and Apple SDKs Agreement. Icons in the interface are SF Symbols,
drawn by macOS, which Apple's licence allows in apps for Apple platforms only.

The app uses the system's fonts only; no font files are included.

## zlib

The app links the copy of zlib that is part of macOS (`libz`), for gzip and zip. zlib is
not included in this repository. Its licence:

> Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler
>
> This software is provided 'as-is', without any express or implied warranty. In no event
> will the authors be held liable for any damages arising from the use of this software.
>
> Permission is granted to anyone to use this software for any purpose, including
> commercial applications, and to alter it and redistribute it freely, subject to the
> following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not claim that you
>    wrote the original software. If you use this software in a product, an
>    acknowledgment in the product documentation would be appreciated but is not required.
> 2. Altered source versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
> 3. This notice may not be removed or altered from any source distribution.

## Services

The app can talk to Samsung's servers (Samsung account and Samsung Cloud, experimental and
unofficial), Google's (Google sign-in and the Google Drive API) and Apple's (iCloud). Their
use is governed by those services' own terms. See `PRIVACY.md` and `TERMS.md`.

## File formats and test files

The app reads and writes the file and sync formats of Samsung Notes so that notes can be
exchanged with Samsung's own apps. The test fixtures in `app/Tests/SamsungNotesKitTests/Fixtures`
are notes written for testing in Samsung Notes, with identifying details replaced; they are
included only to test that interoperability.

## Trademarks

Samsung, Samsung Notes, Samsung Cloud and Galaxy are trademarks of Samsung Electronics
Co., Ltd. Apple, Mac, macOS, iCloud and Apple Intelligence are trademarks of Apple Inc.
Google and Google Drive are trademarks of Google LLC. Inkpage is not affiliated with,
endorsed by or sponsored by any of them.
