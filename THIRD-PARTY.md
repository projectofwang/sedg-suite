# Third-party notices

This project bundles or drives the following upstream software at install time.
Binaries are downloaded from official releases and verified by SHA-256 in
`approved-releases.json`. No source is vendored in this repo.

- AdGuard DNSProxy (https://github.com/AdguardTeam/dnsproxy) - Apache-2.0.
  Local DoH gateway binary `dnsproxy.exe`. License text verified from the
  upstream LICENSE file.
- Zapret (https://github.com/bol-van/zapret) - MIT (Copyright (c) 2016-2024
  bol-van, verified from upstream `docs/LICENSE.txt`).
  DPI-bypass runtime `winws.exe` plus WinDivert driver (`WinDivert64.sys`,
  `WinDivert.dll`) and `cygwin1.dll`. WinDivert itself (https://www.reqrypt.org/windivert.html)
  is dual-licensed LGPLv3-or-later or GPLv2-or-later (used here under LGPLv3);
  `cygwin1.dll` is GPL-3.0-or-later with the Cygwin runtime linking exception
  (https://cygwin.com/licensing.html). See the zapret release notes for details.
- NSSM - Non-Sucking Service Manager (https://nssm.cc/) - public domain.
  Service wrapper `nssm.exe`.

Trademarks belong to their owners.
