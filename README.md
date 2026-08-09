# OpenBoard update feed

This branch is **not source**. It is an orphan branch holding one file — `appcast.xml`,
the Sparkle update feed — served by Cloudflare Workers static assets at
<https://updates.openboardapp.com/appcast.xml>.

Do not merge it into `main`, and do not edit it by hand. `mac/tools/appcast.sh` appends
one `<item>` per release to `public/appcast.xml` and commits here; the release workflow
pushes it, and Cloudflare Workers Builds deploys on push. Hand edits will be overwritten
or, worse, will break the insertion point the script looks for (`</language>`).

`wrangler.jsonc` declares `public/` as the assets directory. Only files inside `public/`
are served — this README and the config itself return 404, which is deliberate.

## Why it is separate

The feed URL is compiled into every build ever shipped and is read by installed copies
forever, so it has to live somewhere with a permanent address that is not tied to a
GitHub account or repository name.

It is an orphan branch — sharing no history with `main` — because a branch that did share
history would publish the entire repository to the web. Keeping it separate also keeps
release churn out of `main`, since the appcast changes on every release and is not
something anyone reviews.

## Verifying

The signature on each item is EdDSA, made with a private key held in one keychain and
verified against the public key compiled into the app. A feed served from the wrong place,
or altered in transit, fails that check and the update is refused.
