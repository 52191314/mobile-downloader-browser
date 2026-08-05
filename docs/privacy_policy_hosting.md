# Host a Privacy Policy URL (no website needed)

Play Console only needs a **public https URL**. You do **not** need to buy a domain.

## Recommended: GitHub Pages (free)

You already have a GitHub repo for Aurora. Use it.

**Important:** `docs/.nojekyll` disables Jekyll so the whole `docs/` tree is served as **static files**. That avoids Pages build failures when Jekyll chokes on project markdown.

### Option A — File in this repo (simplest)

1. Ensure these are on the Pages branch (e.g. `Play-Console-Launch`):
   - `docs/privacy.html` (policy page)
   - `docs/.nojekyll` (disables Jekyll)
   - `docs/index.html` (optional landing link)
2. On GitHub: **Settings → Pages**  
   - Source: **Deploy from a branch**  
   - Branch: `Play-Console-Launch`  
   - Folder: `/docs`  
3. Save. After the Pages action succeeds, open:

```text
https://52191314.github.io/mobile-downloader-browser/privacy.html
```

Also works:

```text
https://52191314.github.io/mobile-downloader-browser/
```

(index links to the privacy policy).

### Option B — Single HTML page (most reliable for Play)

1. Copy `docs/privacy_policy.md` content into a file `docs/privacy.html` (or use GitHub’s automatic rendering of the `.md` page).  
2. Same Pages setup as above.  
3. Use the **exact URL** that opens in an **incognito** window without login.

### Option C — No Pages: public Gist

1. Go to [https://gist.github.com](https://gist.github.com)  
2. Paste the privacy policy text  
3. Create **public** gist  
4. Open the gist → click **Raw** → copy that `https://gist.githubusercontent.com/...` URL  

Play usually accepts a raw gist URL. Prefer Pages if the gist looks too “raw” to you.

### Option D — Google Sites (no GitHub)

1. [https://sites.google.com](https://sites.google.com) → blank site  
2. Paste the privacy policy text  
3. Publish → copy public link  

---

## What to paste in Play Console

```text
Privacy policy URL:   <the public https link that works in incognito>
```

Example shape (after Pages is on):

```text
https://52191314.github.io/mobile-downloader-browser/privacy_policy.html
```

**Before submit:**

1. Open the URL in a private/incognito browser (logged out of GitHub).  
2. Replace the contact placeholder with your real email in the policy text.  
3. Paste the same URL into **Store listing** if Console asks there too.

---

## Do not

- Put a fake `https://example.com/privacy`  
- Use a URL that requires login  
- Commit `key.properties` or keystores while publishing docs  
