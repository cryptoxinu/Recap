# Connect CallBrain to Google Drive (one-time setup)

CallBrain can pull your Google Meet notes and transcripts straight from Google Drive. There are **two
ways** — pick whichever fits.

---

## Option A — Zero setup (recommended if you use the Google Drive app)

If you run the **Google Drive desktop app** on this Mac, your Google Meet "Notes by Gemini" already sync to
a real folder on disk. CallBrain can just watch it:

1. **Settings → Auto-import → "Detect Google Drive “Meet Recordings” folder"**.
2. That's it. New notes import themselves as they appear — no sign-in, no Google Cloud, nothing to configure.

If the button can't find the folder, it opens a picker so you can point at it manually (it's usually under
`~/Library/CloudStorage/GoogleDrive-<you>/My Drive/Meet Recordings`).

---

## Option B — Direct Drive connection (no desktop app needed)

This pulls files straight from Drive over the API. It needs a free, one-time Google OAuth client (≈5 min).

### 1. Create a Google Cloud project
1. Go to <https://console.cloud.google.com/> and sign in with the Google account whose Drive you want.
2. Top bar → project dropdown → **New Project** → name it e.g. `CallBrain` → **Create**.

### 2. Enable the Drive API
1. **APIs & Services → Library** → search **Google Drive API** → **Enable**.

### 3. Configure the consent screen (testing mode — no app verification needed)
1. **APIs & Services → OAuth consent screen**.
2. User type: **External** → **Create**.
3. Fill App name (`CallBrain`), your email for support + developer contact → **Save and Continue**.
4. **Scopes**: you can skip adding scopes here (CallBrain requests `drive.readonly` at sign-in).
5. **Test users**: **Add users** → add **your own Google address**. (In testing mode only test users can
   sign in — that's you, which is all you need.) → **Save**.

### 4. Create the OAuth client
1. **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. Application type: **Desktop app** → name it `CallBrain Desktop` → **Create**.
3. Copy the **Client ID** and **Client secret**.

### 5. Connect in CallBrain
1. **Settings → Google Drive (cloud sync) → "Set up Google Drive sync…"**.
2. Paste the **Client ID** and **Client secret** → **Save**.
3. **"Connect Google Drive…"** → your browser opens → choose your account → you'll see an **"unverified
   app"** notice (expected for a personal app in testing mode) → **Continue** / **Advanced → Go to
   CallBrain** → **Allow** (read-only Drive access).
4. The browser shows "connected — close this tab". CallBrain finds your **Meet Recordings** folder and
   starts importing. Use **"Sync now"** any time, or **"Disconnect"** to revoke.

### Notes
- CallBrain requests **read-only** Drive access (`drive.readonly`) and stores your tokens in the macOS
  **Keychain** — never in a plain file.
- Google Docs (Gemini notes) are exported as `.docx` and imported; transcripts (`.txt`/`.vtt`/`.srt`) and
  recordings are downloaded and imported. Duplicates are detected automatically.
- The "client secret" of a Desktop OAuth client is not a true secret (Google's own docs say so for installed
  apps); it's only sent during the token exchange, never embedded in a link.
