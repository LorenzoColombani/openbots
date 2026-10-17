# Application updates

OpenBots Next currently updates from source. A release contains a signed manifest
and an immutable public Git commit. The app builds the verified source with the
recipient's local Xcode and Apple Development certificate. No paid Apple
Developer membership is needed.

## Bootstrap and normal updates

An older installation without the source channel needs the one-time bootstrap
described in [INSTALL.md](INSTALL.md). Bootstrap reads the published release feed
over HTTPS, downloads the one commit it names, and checks every extracted file
against the feed's SHA-256/mode inventory before running anything from it. It
does not check the feed's Ed25519 signature: macOS's built-in Python cannot, so
the first install trusts the feed as GitHub serves it over HTTPS. It then builds
locally, verifies the signed candidate, refuses a downgrade, and replaces only a
stopped OpenBots Next application, in place. One copy of the previous bundle is
kept outside `/Applications`. It does not edit application data or credentials.

After bootstrapping, **Update now** authenticates the manifest before interpreting
it. The manifest contains only the release version, positive ordered build,
forty-character public commit and complete file SHA-256/mode inventory. The app
derives its archive URL from its configured repository and that commit. It checks
the entire extracted tree before executing a build script.

Downloads use the public credential-free route; the build resolves no packages. Builds
run in private staging. The build's isolated compiler environment has no Keychain
directory attached; only narrowly targeted local signing operations use the
recipient's existing Apple Development identity. No private key is exported or
written into a source file, command argument or environment variable.

## Preservation and cancellation

The old 1.0.2 bootstrap carries the installed bundle's public Google client ID
into the new bundle. On first launch the app saves that public setting into its
protected control store. Newer installations can already use this durable
configuration even when their bundle's optional ID is empty. The installer never
reads or writes that database. Google secrets and tokens remain in Keychain.
Invalid configuration, failed persistence or a changing setup blocks unsafe
update admission.

Before installation, the app checks active work, approvals, workers, editing and
draft persistence. Only a successful final check permits normal shutdown.
Cancellation and Quit stop owned build work. The installer verifies candidate
and destination again, waits for the exact app to stop normally, and keeps the
previous application bundle. It never force-quits the app or changes the legacy
OpenBots installation. A running replacement is never overwritten during recovery.

An application backup is not a database backup. Rolling back the bundle cannot
undo later database migrations or work. Keep the previous bundle until the new
app has opened and the saved work has been checked.

Going back to a version before 1.1 with the same data is not supported. Earlier
versions open the database but cannot read the model details 1.1 saves with each
reply, so conversations with newer replies fail to load there.

## Release and fork configuration

`Config/ReleaseBuild.xcconfig` declares an explicit positive ordered build number.
Advance it for every distributed candidate; source commit identity is separate.
Source updates use these application configuration fields:

- `OpenBotsSourceUpdateEnabled`
- `OpenBotsSourceUpdateFeedURL`
- `OpenBotsSourceUpdatePublicKey`
- `OpenBotsSourceUpdateRepository`

The production feed is
`https://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json`.
Its manifest points to an earlier immutable source commit, avoiding a feed that
must contain its own hash.

Forks must use their own signing key, repository and feed validation policy, or
leave updates disabled. Ship only the public Ed25519 key and keep the private key
out of the repository. Do not copy another maintainer's signing identity, Google
configuration, profile, data, receipts or build caches into public source.
