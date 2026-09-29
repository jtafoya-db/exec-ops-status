# Third-party notices

This app ships prebuilt (`dist/` is a copy of `public/` plus the compiled
client bundle), so the components below are redistributed with it. Nothing is
fetched from a CDN at runtime: every script, stylesheet and font is served
from the app itself.

| Component | Version | License | Where it ships |
|---|---|---|---|
| React | 18.3.1 | MIT | `public/mockup/vendor/react/` (UMD build, used by the mockup); compiled into `dist/assets/index-*.js` |
| ReactDOM | 18.3.1 | MIT | `public/mockup/vendor/react-dom/` (UMD build); compiled into `dist/assets/index-*.js` |
| scheduler (ReactDOM dependency) | 0.23.2 | MIT | compiled into `dist/assets/index-*.js` |
| @babel/standalone | 7.29.0 | MIT | `public/mockup/vendor/babel-standalone/` |
| @databricks/aibi-client | 1.1.0 | Databricks License (full text below) | compiled into `dist/assets/index-*.js` |
| U.S. Web Design System (USWDS) design tokens and styles | n/a | Public domain in the U.S. (CC0 1.0 worldwide) | `public/mockup/_ds/` |
| Material Icons glyph geometry (inline SVG paths in the USWDS component bundle) | n/a | Apache-2.0 | `public/mockup/_ds/.../_ds_bundle.js` |
| Merriweather | n/a | SIL OFL 1.1 | `public/mockup/_ds/uswds-design-system-fc84de71-1424-4bd8-b936-f021f2d10c14/assets/fonts/` (license: `OFL-Merriweather.txt`) |
| Public Sans | n/a | SIL OFL 1.1 | `public/mockup/_ds/uswds-design-system-fc84de71-1424-4bd8-b936-f021f2d10c14/assets/fonts/` (license: `OFL-PublicSans.txt`) |
| Source Sans Pro | n/a | SIL OFL 1.1 | `public/mockup/_ds/uswds-design-system-fc84de71-1424-4bd8-b936-f021f2d10c14/assets/fonts/` (license: `OFL-SourceSansPro.txt`) |
| Roboto Mono | n/a | Apache-2.0 | `public/mockup/_ds/uswds-design-system-fc84de71-1424-4bd8-b936-f021f2d10c14/assets/fonts/` (license: `LICENSE-RobotoMono.txt`) |

The vendored React, ReactDOM and Babel files are the unmodified files from the
published npm packages. They match the SHA-384 subresource-integrity hashes
pinned in `public/mockup/support.js`, and each directory carries the package's
`LICENSE` file.

## React, ReactDOM, scheduler (MIT)

MIT License

Copyright (c) Facebook, Inc. and its affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## @babel/standalone (MIT)

See `public/mockup/vendor/babel-standalone/LICENSE`
(Copyright (c) 2014-present Sebastian McKenzie and other contributors).

## USWDS (public domain / CC0 1.0)

The U.S. Web Design System is a work of the U.S. General Services
Administration. As a work of the United States government it is in the public
domain within the United States, and copyright and related rights worldwide are
waived through the CC0 1.0 Universal public domain dedication
(https://creativecommons.org/publicdomain/zero/1.0/). Source:
https://github.com/uswds/uswds

## Fonts

Merriweather, Public Sans and Source Sans Pro are licensed under the SIL Open
Font License, Version 1.1. Roboto Mono and the Material Icons geometry are
licensed under the Apache License, Version 2.0. The full license texts, with
each font's copyright notice, are next to the font files in
`public/mockup/_ds/uswds-design-system-fc84de71-1424-4bd8-b936-f021f2d10c14/assets/fonts/`.

## @databricks/aibi-client (Databricks License)

`@databricks/aibi-client` is compiled into the client bundle. Its license
requires giving recipients a copy of the license, which is reproduced in full
below, as shipped in the package's `LICENSE` file.

# DB license

**Definitions.**

Agreement: The agreement between Databricks, Inc., and you governing the use of the Databricks Services, as that term is defined in the Master Cloud Services Agreement (MCSA) located at www.databricks.com/legal/mcsa.

Licensed Materials: The source code, object code, data, and/or other works to which this license applies.

**Scope of Use.** You may not use the Licensed Materials except in connection with your use of the Databricks Services pursuant to the Agreement. Your use of the Licensed Materials must comply at all times with any restrictions applicable to the Databricks Services, generally, and must be used in accordance with any applicable documentation. You may view, use, copy, modify, publish, and/or distribute the Licensed Materials solely for the purposes of using the Licensed Materials within or connecting to the Databricks Services. If you do not agree to these terms, you may not view, use, copy, modify, publish, and/or distribute the Licensed Materials.

**Redistribution.** You may redistribute and sublicense the Licensed Materials so long as all use is in compliance with these terms. In addition:

* You must give any other recipients a copy of this License;  
* You must cause any modified files to carry prominent notices stating that you changed the files;  
* You must retain, in any derivative works that you distribute, all copyright, patent, trademark, and attribution notices, excluding those notices that do not pertain to any part of the derivative works; and  
* If a "NOTICE" text file is provided as part of its distribution, then any derivative works that you distribute must include a readable copy of the attribution notices contained within such NOTICE file, excluding those notices that do not pertain to any part of the derivative works.

You may add your own copyright statement to your modifications and may provide additional license terms and conditions for use, reproduction, or distribution of your modifications, or for any such derivative works as a whole, provided your use, reproduction, and distribution of the Licensed Materials otherwise complies with the conditions stated in this License.

**Termination.** This license terminates automatically upon your breach of these terms or upon the termination of your Agreement. Additionally, Databricks may terminate this license at any time on notice. Upon termination, you must permanently delete the Licensed Materials and all copies thereof.  
 

**DISCLAIMER; LIMITATION OF LIABILITY.**

THE LICENSED MATERIALS ARE PROVIDED “AS-IS” AND WITH ALL FAULTS. DATABRICKS, ON BEHALF OF ITSELF AND ITS LICENSORS, SPECIFICALLY DISCLAIMS ALL WARRANTIES RELATING TO THE LICENSED MATERIALS, EXPRESS AND IMPLIED, INCLUDING, WITHOUT LIMITATION, IMPLIED WARRANTIES, CONDITIONS AND OTHER TERMS OF MERCHANTABILITY, SATISFACTORY QUALITY OR FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT. DATABRICKS AND ITS LICENSORS TOTAL AGGREGATE LIABILITY RELATING TO OR ARISING OUT OF YOUR USE OF OR DATABRICKS’ PROVISIONING OF THE LICENSED MATERIALS SHALL BE LIMITED TO ONE THOUSAND ($1,000) DOLLARS.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE LICENSED MATERIALS OR THE USE OR OTHER DEALINGS IN THE LICENSED MATERIALS.
