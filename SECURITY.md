# Security

Doorstep handles access to people's home cameras, so security problems matter a lot.

## Reporting a problem
**Please don't open a public issue for security problems.** Report them privately through GitHub: **[Report a vulnerability](https://github.com/iinde/doorstep/security/advisories/new)**. Include what you found, how to reproduce it and what an attacker could do. We'll reply as soon as we can and credit you in the fix unless you'd rather we didn't.

## What's in scope
- How Doorstep stores Ring tokens, keys and data on the Mac
- The update system (signing and verification)
- Anything that could expose video, recordings or account access
- Anything that sends data somewhere it shouldn't

## How Doorstep protects you
- **Sign-in tokens and keys** live in the macOS Keychain. Passwords aren't stored.
- **Updates** are signed with an EdDSA key held only by the maintainers. The app verifies that signature and Apple's code signature before installing; unsigned or altered updates are refused.
- **No servers.** There's no Doorstep backend to breach.
- **Optional services** (Claude, 17TRACK, Microsoft, Open-Meteo) are off unless the user turns them on, and use the user's own keys.
