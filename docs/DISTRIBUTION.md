# Shipping Tarn: hosting, updates, costs, payments

Verified 2026-11-01. Re-check prices before you rely on them.

## Where the app lives

| What | Where | Cost |
|---|---|---|
| `Tarn.dmg` and update zips | GitHub Releases on a **public** repo, e.g. `Rishab87/tarn-releases`. The source can stay private. | Free. Files under 2 GiB each, no bandwidth cap (GitHub's acceptable-use policy can throttle abuse). |
| `appcast.xml` (Sparkle update feed) | An asset on the same release, served from `https://github.com/Rishab87/tarn-releases/releases/latest/download/appcast.xml` | Free |
| Website | Cloudflare Pages | Free, commercial use allowed. Its 25 MiB file limit is why the DMG lives on GitHub. |
| AI models | Downloaded by the app straight from Hugging Face | Free to you. Anonymous limit is 3,000 downloads per IP per 5 minutes. |

- **Not Vercel Hobby once you charge.** Hobby is "non-commercial personal use only", and that explicitly includes taking payments. Vercel Pro costs $20/month.
- **Alternative to GitHub:** Cloudflare R2 has 10 GB free and free egress. Use a custom domain, because `r2.dev` URLs are rate-limited.
- Download button link that always points to the newest release: `https://github.com/Rishab87/tarn-releases/releases/latest/download/Tarn.dmg`

## Required: Apple Developer ID + notarization

- An unsigned or un-notarized download is blocked by Gatekeeper.
- Since macOS Sequoia, the Control-click "Open" bypass is gone. Users would have to dig through System Settings, and most won't.
- Your existing Apple Developer membership ($99/yr, already paid for TerraDex) covers this.
- What you need:
  - A **Developer ID Application** certificate. Make it in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application. Only the account holder can do this, which is you.
  - An App Store Connect API key (or an app-specific password) for `notarytool`.

## How updates reach users (Sparkle 2)

1. The app checks the appcast every time it opens.
2. With "Update Tarn automatically" on (the default), it downloads the update in the background and installs it when Tarn quits. With it off, it asks first.
3. Updates are verified two ways:
   - the EdDSA signature in the appcast, checked against `SUPublicEDKey` in Info.plist;
   - Apple code signing, which must match the installed app.
4. To ship an update:
   - bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`;
   - archive, sign with Developer ID, notarize, staple;
   - zip the app, sign the zip with the EdDSA key, add an `<item>` to `appcast.xml`;
   - upload the DMG, zip and appcast to a new GitHub release.

The release script comes in the distribution step. The EdDSA private key will be generated into your login Keychain. **Back it up**: losing it means you can't ship updates to existing users without a key-rotation release.

**New models ship the same way.** Add the model to `scripts/catalog.source.json`, run `python3 scripts/build_catalog.py`, and release. On next launch, Macs where the new model is the better pick see "There's a smarter AI for your Mac". Fixes to the same model file (new SHA-256 on Hugging Face) show "An improved version of your AI is available".

## Selling a one-time license from the website

**Use Polar** (polar.sh):
- It onboards individuals in India and pays out via Stripe Connect Express, even though standalone Stripe is invite-only in India.
- Built-in license keys with activation limits, and a validate endpoint that needs no server.
- Fees: 5% + 50¢ per sale, +1.5% on non-US cards. Payouts: $2/month while active, plus 0.25% + 25¢ per payout and 1% currency conversion.

Fallback: **Dodo Payments**. It's India-based, charges 4% + 40¢, and pays USD only with a $25 SWIFT fee.

Avoid:
- **Lemon Squeezy.** Indian payouts are PayPal-only without Stripe approval, and the company is steering users to Stripe Managed Payments, which doesn't support India.
- **Paddle Billing.** No license keys.
- **Gumroad.** 10% + 50¢.

## Mac App Store, later

- Paid apps pay 15% commission under the Small Business Program.
- The App Store build would be a reduced version:
  - App Store apps may not self-update (guideline 2.4.5(vii)) or require license keys (2.4.5(vi)), so it's a paid download.
  - The sandbox blocks running arbitrary commands and user-installed tools like `npx`, so the folder agent's commands and local connectors go away.
  - The bundled engine is allowed as a sandboxed helper in Contents/MacOS. FreeChat ships this way.
  - Downloading models after install is accepted in practice: Private LLM and RecurseChat both do it.
- Recommendation: sell direct first. Add the App Store version only once direct sales prove demand.
