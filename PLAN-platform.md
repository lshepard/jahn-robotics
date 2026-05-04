# Jahn Robotics Platform — Detailed Implementation Plan

## Background & Context

### What exists today

**jahnrobotics.com** (`/Users/luke/code/jahnrobotics`) is an Astro 5 static site hosted on Vercel. It showcases the Jahn Elementary School FLL robotics program. The site has:
- Astro 5.17.1 + Tailwind CSS 4 + TypeScript
- Pages: home, about, teams (by season)
- Content: markdown-based team/season profiles
- No authentication, no backend, no API routes
- Deployed on Vercel (no deployment config files in repo — configured via Vercel dashboard)
- Domain: `jahnrobotics.com`
- Repo: `git@github.com:lshepard/jahn-robotics.git`

**XRPWeb** (`/Users/luke/code/robots/xrp/XRPWeb`) is a web-based IDE for the XRP robotics platform:
- React 18 + TypeScript + Vite 6
- Blockly visual editor + Monaco Python editor
- Connects to XRP robots via USB/Bluetooth
- Currently uses Google OAuth + Google Drive for cloud file storage
- Stores open editor content in `localStorage['EditorStores']` as JSON array of `{ id, name, path, content, isBlockly, isSavedToXRP }`
- Active tab tracked in `localStorage['ActiveTab']`
- Event system via `mitt` library, accessible through `AppMgr.getInstance()`
- Builds to static `dist/` folder, base URL is `./` (works in any subdirectory)
- Currently deployed to GitHub Pages
- Repo: `git@github.com:Open-STEM/XRPWeb.git` (upstream, not a personal fork)
- Version: 2.0.9, GPL-2.0 license

**Pybricks Code** (`https://github.com/pybricks/pybricks-code`) is the web IDE at code.pybricks.com:
- React 18 + TypeScript + Redux + Webpack 5
- Monaco editor + Pyodide (Python in WASM)
- Uses Dexie.js (IndexedDB wrapper) for file storage
  - Database: `pybricks.fileStorage` (Dexie v1 = IndexedDB v10)
  - Object store `metadata`: `{ uuid, path, sha256, viewState }`
  - Object store `_contents`: `{ path, contents }`
  - Uses Web Locks API for concurrency control
- Build: `yarn install && yarn build` → `build/` folder
- Requires Node 18, Yarn 1.x
- MIT license

**pybricks-autosave** (`/Users/luke/code/pybricks-autosave`) is a Chrome extension that syncs Pybricks files to Google Drive:
- Chrome Extension (Manifest V3)
- Content script reads from Pybricks IndexedDB every 5 seconds
- Background script syncs to Google Drive via REST API
- Uses Google OAuth 2.0 for auth
- Repo: `git@github.com:lshepard/pybricks-autosave.git`
- This extension demonstrates how to read/write Pybricks' IndexedDB from external code

### What we want to build

A platform where:
1. Coaches create team accounts (no student PII — FERPA compliance)
2. Teams log in with a simple team name + password
3. Students use XRPWeb and Pybricks Code hosted on our subdomains
4. They can save/load their code files with dated version history
5. Coaches can see all their teams' files from a dashboard
6. The coding tool forks stay as close to upstream as possible (1 new file + 1 import line each)

---

## Design Principles

1. **All auth, storage, and UI for file management live in the jahnrobotics repo.** The coding tool forks get only one tiny new file each.
2. **FERPA compliant.** No student PII stored. Accounts are team/group names. No emails, no real student names.
3. **Simple shared workspaces.** Each account (team/group) has its own file space. All members sharing that login see the same files.
4. **Dated snapshots for version history.** Every save creates a timestamped snapshot. Students can browse and restore old versions.
5. **Minimal fork divergence.** Each fork has 1 new file + 1 modified line. Upstream merges should almost never conflict.

---

## Architecture

```
jahnrobotics.com                    — Astro 5 site (this repo)
  /                                 — existing homepage
  /about, /teams/*                  — existing pages
  /login                            — team/group login (team name + password)
  /coach                            — coach dashboard (create teams, view files)
  /files                            — team file browser (view snapshots, restore)
  /pybricks                         — fallback upload page for Pybricks files
  /api/auth/login                   — POST: authenticate, set cookie
  /api/auth/logout                  — POST: clear cookie
  /api/auth/me                      — GET: current session info
  /api/teams/create                 — POST: coach creates team account
  /api/teams/list                   — GET: coach lists their teams
  /api/files/save                   — POST: save file snapshot
  /api/files/load                   — GET: list files / load specific file
  /api/files/history                — GET: version history for a file

pybricks.jahnrobotics.com           — Pybricks Code fork (React/Webpack)
  src/jahn-sync.ts (1 new file)     — "Save to Jahn" / "Load from Jahn" buttons

xrp.jahnrobotics.com                — XRPWeb fork (React/Vite)
  src/jahn-sync.ts (1 new file)     — "Save to Jahn" / "Load from Jahn" buttons

             ↓ all API routes talk to ↓
           Supabase (auth + postgres)
```

**Three separate Vercel projects.** Each subdomain is its own Vercel project linked to its own Git repo. This keeps the forks independent and allows clean upstream merges.

---

## Data Model

### Supabase Auth

Supabase auth users represent **teams/groups**, not individuals:
- **Team accounts**: Login with team name + password. Supabase requires an email field, so we use synthetic emails like `gearginders@jahnrobotics.local`. Students never see these. The login form only shows "Team Name" and "Password" fields.
- **Coach accounts**: Also Supabase auth users, but with `user_metadata: { is_coach: true }`. Created manually in the Supabase dashboard or via invite. Coaches log in with their actual email + password (or also a username — up to you).

**Important Supabase config**: Disable email confirmation for signups (since team accounts use synthetic emails that can't receive mail).

### Database Schema

```sql
-- ============================================================
-- ACCOUNTS TABLE
-- Represents teams/groups. Links a Supabase auth user to a
-- display name and the coach who created it.
-- ============================================================
create table public.accounts (
  id uuid references auth.users(id) on delete cascade primary key,
  name text not null,            -- display name: "Gear Grinders"
  created_by uuid not null,      -- coach's auth.users id
  tool text,                     -- optional: 'xrp', 'pybricks', or null (= both)
  created_at timestamptz default now()
);

-- ============================================================
-- FILE VERSIONS TABLE
-- Every save creates a new row. This is the version history.
-- ============================================================
create table public.file_versions (
  id uuid default gen_random_uuid() primary key,
  account_id uuid references auth.users(id) on delete cascade not null,
  tool text not null check (tool in ('xrp', 'pybricks')),
  file_name text not null,       -- e.g. "main.py", "robot_turn.py"
  content text not null,         -- full file content
  file_type text,                -- 'python' or 'blockly'
  label text,                    -- optional student note: "added turn logic"
  created_at timestamptz default now()
);

-- Index for fast file lookups
create index idx_file_versions_lookup
  on public.file_versions (account_id, tool, file_name, created_at desc);

-- View: latest version of each file per account
-- Usage: SELECT * FROM current_files WHERE account_id = '...' AND tool = 'xrp'
create view public.current_files as
  select distinct on (account_id, tool, file_name) *
  from public.file_versions
  order by account_id, tool, file_name, created_at desc;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.accounts enable row level security;
alter table public.file_versions enable row level security;

-- Teams can CRUD their own files
create policy "own_files" on public.file_versions
  for all using (auth.uid() = account_id);

-- Coaches can read accounts they created
create policy "coach_sees_accounts" on public.accounts
  for select using (auth.uid() = created_by);

-- Teams can read their own account record
create policy "own_account" on public.accounts
  for select using (auth.uid() = id);

-- Coaches can read files for accounts they created
create policy "coach_reads_files" on public.file_versions
  for select using (
    account_id in (
      select id from public.accounts where created_by = auth.uid()
    )
  );
```

---

## Auth Sharing Across Subdomains (Shared Cookie)

After login at `jahnrobotics.com/login`, the API sets an HTTP cookie:

```
Set-Cookie: jahn_session=<JWT>; Domain=.jahnrobotics.com; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=604800
```

This cookie is automatically available on all `*.jahnrobotics.com` subdomains.

**How it works in the coding tools:**
- `jahn-sync.ts` calls `fetch('https://jahnrobotics.com/api/files/save', { credentials: 'include' })`
- The browser automatically includes the `jahn_session` cookie (same parent domain)
- The API endpoint reads the cookie, validates the JWT with Supabase, proceeds
- `jahn-sync.ts` does NOT manage auth tokens — it just calls fetch and handles 401s by redirecting to login

**CORS configuration needed:** The API routes on `jahnrobotics.com` must return:
```
Access-Control-Allow-Origin: https://xrp.jahnrobotics.com  (or https://pybricks.jahnrobotics.com)
Access-Control-Allow-Credentials: true
Access-Control-Allow-Methods: GET, POST
Access-Control-Allow-Headers: Content-Type
```

This can be handled in the Astro API routes or via Vercel headers config.

**Login redirect flow:**
1. Student goes to `xrp.jahnrobotics.com`, clicks "Save to Jahn"
2. `jahn-sync.ts` calls `/api/files/save` → gets 401 (no cookie)
3. Redirects to `jahnrobotics.com/login?redirect=https://xrp.jahnrobotics.com`
4. Student logs in → cookie set on `.jahnrobotics.com` → redirected back
5. Clicks "Save to Jahn" again → cookie present → success

**Logout:** Any page can POST to `/api/auth/logout` which clears the cookie. Since the cookie is on `.jahnrobotics.com`, it's cleared for all subdomains.

---

## XRPWeb Integration Details

### How XRPWeb stores files (what jahn-sync.ts reads)

XRPWeb persists all open editor tabs to `localStorage['EditorStores']`:

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "name": "main.py",
    "path": "/users/main.py",
    "content": "from XRPLib.defaults import *\n\ndef drive_forward():\n    drivetrain.straight(20)\n",
    "isBlockly": false,
    "isSavedToXRP": true
  },
  {
    "id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "name": "turns.blocks",
    "path": "/users/turns.blocks",
    "content": "<xml>...</xml>",
    "isBlockly": true,
    "isSavedToXRP": false
  }
]
```

The active tab is in `localStorage['ActiveTab']` (a quoted UUID string).

Every keystroke auto-saves to localStorage (via MonacoEditor's `onDidChangeModelContent` handler in `src/components/MonacoEditor.tsx`).

### jahn-sync.ts for XRPWeb

One self-contained file. No dependencies beyond native browser APIs.

```typescript
// src/jahn-sync.ts
// Jahn Robotics cloud save integration for XRPWeb.
// This is the ONLY custom file in the XRPWeb fork.

const JAHN_API = 'https://jahnrobotics.com/api';
const JAHN_LOGIN = 'https://jahnrobotics.com/login';

// ---- Read from XRPWeb's localStorage ----

function getActiveEditorContent(): { name: string; content: string; type: string } | null {
  const stores = JSON.parse(localStorage.getItem('EditorStores') || '[]');
  const activeId = localStorage.getItem('ActiveTab')?.replace(/"/g, '');
  const active = stores.find((s: any) => s.id === activeId);
  if (!active) return null;
  return {
    name: active.name,
    content: active.content,
    type: active.isBlockly ? 'blockly' : 'python'
  };
}

function getAllEditorContents(): Array<{ name: string; content: string; type: string }> {
  const stores = JSON.parse(localStorage.getItem('EditorStores') || '[]');
  return stores.map((s: any) => ({
    name: s.name,
    content: s.content,
    type: s.isBlockly ? 'blockly' : 'python'
  }));
}

function setEditorContent(name: string, content: string, isBlockly: boolean): void {
  const stores = JSON.parse(localStorage.getItem('EditorStores') || '[]');
  const existing = stores.find((s: any) => s.name === name);
  if (existing) {
    existing.content = content;
  } else {
    stores.push({
      id: crypto.randomUUID(),
      name,
      path: `/users/${name}`,
      content,
      isBlockly,
      isSavedToXRP: false
    });
  }
  localStorage.setItem('EditorStores', JSON.stringify(stores));
  // Trigger page reload to pick up the new content
  // (XRPWeb reads EditorStores on mount)
}

// ---- API calls ----

async function apiCall(endpoint: string, options: RequestInit = {}): Promise<Response> {
  const res = await fetch(`${JAHN_API}${endpoint}`, {
    ...options,
    credentials: 'include', // sends the shared cookie
    headers: { 'Content-Type': 'application/json', ...options.headers }
  });
  if (res.status === 401) {
    window.location.href = `${JAHN_LOGIN}?redirect=${encodeURIComponent(window.location.href)}`;
    throw new Error('Not authenticated');
  }
  return res;
}

async function saveToJahn(): Promise<void> {
  const file = getActiveEditorContent();
  if (!file) { showToast('No file open to save', 'error'); return; }
  try {
    await apiCall('/files/save', {
      method: 'POST',
      body: JSON.stringify({
        tool: 'xrp',
        file_name: file.name,
        content: file.content,
        file_type: file.type
      })
    });
    showToast(`Saved "${file.name}"`, 'success');
  } catch (e) {
    if ((e as Error).message !== 'Not authenticated') {
      showToast('Save failed', 'error');
    }
  }
}

async function loadFromJahn(): Promise<void> {
  try {
    const res = await apiCall('/files/load?tool=xrp');
    const files = await res.json();
    // Show a simple picker modal...
    // (implementation: create a modal div with file list, click to load)
  } catch (e) {
    if ((e as Error).message !== 'Not authenticated') {
      showToast('Load failed', 'error');
    }
  }
}

// ---- UI injection ----

function showToast(message: string, type: 'success' | 'error'): void {
  const toast = document.createElement('div');
  toast.textContent = message;
  toast.style.cssText = `position:fixed;bottom:70px;right:20px;z-index:10000;padding:8px 16px;
    background:${type === 'success' ? '#16a34a' : '#dc2626'};color:white;border-radius:8px;
    font-size:14px;box-shadow:0 2px 8px rgba(0,0,0,0.2);transition:opacity 0.3s;`;
  document.body.appendChild(toast);
  setTimeout(() => { toast.style.opacity = '0'; setTimeout(() => toast.remove(), 300); }, 2000);
}

function injectUI(): void {
  const container = document.createElement('div');
  container.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:9999;display:flex;gap:8px;';

  const saveBtn = document.createElement('button');
  saveBtn.textContent = 'Save to Jahn';
  saveBtn.style.cssText = 'padding:8px 16px;background:#2563eb;color:white;border:none;border-radius:8px;cursor:pointer;font-size:14px;box-shadow:0 2px 8px rgba(0,0,0,0.2);';
  saveBtn.onclick = saveToJahn;

  const loadBtn = document.createElement('button');
  loadBtn.textContent = 'Load from Jahn';
  loadBtn.style.cssText = 'padding:8px 16px;background:#7c3aed;color:white;border:none;border-radius:8px;cursor:pointer;font-size:14px;box-shadow:0 2px 8px rgba(0,0,0,0.2);';
  loadBtn.onclick = loadFromJahn;

  container.appendChild(saveBtn);
  container.appendChild(loadBtn);
  document.body.appendChild(container);
}

// Wait for DOM, then inject
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', injectUI);
} else {
  injectUI();
}
```

### Change to main.tsx (1 line)

```diff
+ import './jahn-sync';
```

Add this import near the top of `src/main.tsx`. Since jahn-sync.ts is a side-effect-only module (it self-initializes), a bare import is sufficient.

---

## Pybricks Code Integration Details

### How Pybricks stores files (what jahn-sync.ts reads)

Pybricks Code uses Dexie.js to wrap IndexedDB:
- Database: `pybricks.fileStorage`
- Table `_contents`: `{ path: string, contents: string }`
- Table `metadata`: `{ uuid: string, path: string, sha256: string, viewState: any }`

To read files, open the IndexedDB directly (since jahn-sync.ts doesn't import Dexie):

```typescript
function openPybricksDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('pybricks.fileStorage', 10);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function getAllPybricksFiles(): Promise<Array<{ path: string; contents: string }>> {
  const db = await openPybricksDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(['_contents'], 'readonly');
    const store = tx.objectStore('_contents');
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
```

### jahn-sync.ts for Pybricks

Same pattern as XRPWeb but reads from IndexedDB instead of localStorage. The API calls and UI injection are identical. The `tool` field in API calls is `'pybricks'` instead of `'xrp'`.

### Change to entry point (1 line)

Add `import './jahn-sync'` to `src/index.tsx` (Pybricks' entry point).

### Pybricks build notes

- Uses Webpack 5, not Vite
- Build: `yarn build` → `build/` folder
- Requires Node 18, Yarn 1.x
- For Vercel deployment: set build command to `yarn build`, output directory to `build`

---

## Astro Configuration Changes

### Switch from static to server-rendered (for API routes)

Currently `astro.config.mjs`:
```javascript
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://jahnrobotics.com',
  integrations: [sitemap()],
  vite: { plugins: [tailwindcss()] }
});
```

Updated:
```javascript
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';
import react from '@astrojs/react';
import vercel from '@astrojs/vercel';

export default defineConfig({
  site: 'https://jahnrobotics.com',
  output: 'server',            // enables API routes + SSR
  adapter: vercel(),            // deploy to Vercel serverless
  integrations: [sitemap(), react()],
  vite: { plugins: [tailwindcss()] }
});
```

The `output: 'server'` mode means all pages are server-rendered by default. Existing static pages (home, about, teams) should add `export const prerender = true` to stay static. Alternatively, use `output: 'hybrid'` where pages are static by default and only API routes are server-rendered.

**`output: 'hybrid'` is probably better** — it keeps existing pages static (no changes needed) and only the new API routes and dynamic pages run server-side. In hybrid mode, API routes in `src/pages/api/` are server-rendered by default.

---

## API Route Implementations

### POST /api/auth/login

```typescript
// src/pages/api/auth/login.ts
import type { APIRoute } from 'astro';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  import.meta.env.SUPABASE_URL,
  import.meta.env.SUPABASE_ANON_KEY
);

export const POST: APIRoute = async ({ request }) => {
  const { team_name, password } = await request.json();
  const email = `${team_name.toLowerCase().replace(/\s+/g, '-')}@jahnrobotics.local`;

  const { data, error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    return new Response(JSON.stringify({ error: 'Invalid team name or password' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // Set cookie on parent domain
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.append('Set-Cookie',
    `jahn_session=${data.session.access_token}; Domain=.jahnrobotics.com; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=604800`
  );
  // Also store refresh token
  headers.append('Set-Cookie',
    `jahn_refresh=${data.session.refresh_token}; Domain=.jahnrobotics.com; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=604800`
  );

  const isCoach = data.user.user_metadata?.is_coach === true;

  return new Response(JSON.stringify({
    ok: true,
    is_coach: isCoach,
    name: isCoach ? data.user.email : team_name
  }), { status: 200, headers });
};
```

### POST /api/files/save

```typescript
// src/pages/api/files/save.ts
import type { APIRoute } from 'astro';
import { createClient } from '@supabase/supabase-js';

export const POST: APIRoute = async ({ request, cookies }) => {
  const token = cookies.get('jahn_session')?.value;
  if (!token) return new Response('Unauthorized', { status: 401 });

  const supabase = createClient(
    import.meta.env.SUPABASE_URL,
    import.meta.env.SUPABASE_ANON_KEY,
    { global: { headers: { Authorization: `Bearer ${token}` } } }
  );

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response('Unauthorized', { status: 401 });

  const { tool, file_name, content, file_type, label } = await request.json();

  const { error } = await supabase.from('file_versions').insert({
    account_id: user.id,
    tool,
    file_name,
    content,
    file_type,
    label
  });

  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  // CORS headers for subdomain requests
  const headers = new Headers({ 'Content-Type': 'application/json' });
  const origin = request.headers.get('Origin');
  if (origin?.endsWith('.jahnrobotics.com')) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
};
```

### GET /api/files/load

```typescript
// src/pages/api/files/load.ts
import type { APIRoute } from 'astro';
import { createClient } from '@supabase/supabase-js';

export const GET: APIRoute = async ({ request, cookies, url }) => {
  const token = cookies.get('jahn_session')?.value;
  if (!token) return new Response('Unauthorized', { status: 401 });

  const supabase = createClient(
    import.meta.env.SUPABASE_URL,
    import.meta.env.SUPABASE_ANON_KEY,
    { global: { headers: { Authorization: `Bearer ${token}` } } }
  );

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response('Unauthorized', { status: 401 });

  const tool = url.searchParams.get('tool');
  const fileName = url.searchParams.get('file_name');

  let query = supabase.from('current_files').select('*').eq('account_id', user.id);
  if (tool) query = query.eq('tool', tool);
  if (fileName) query = query.eq('file_name', fileName);

  const { data, error } = await query;
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  const headers = new Headers({ 'Content-Type': 'application/json' });
  const origin = request.headers.get('Origin');
  if (origin?.endsWith('.jahnrobotics.com')) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
  }

  return new Response(JSON.stringify(data), { status: 200, headers });
};
```

### CORS Preflight Handler

All API routes that accept cross-origin requests need to handle OPTIONS:

```typescript
export const OPTIONS: APIRoute = async ({ request }) => {
  const origin = request.headers.get('Origin');
  const headers = new Headers();
  if (origin?.endsWith('.jahnrobotics.com')) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
    headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }
  return new Response(null, { status: 204, headers });
};
```

---

## Implementation Phases

### Phase 1: Login System

Get auth working and deployed. Coach can create teams, teams can log in.

**Supabase setup (manual in dashboard):**
1. Create project
2. Run accounts table SQL (skip file_versions for now)
3. Auth settings: enable email/password, **disable email confirmation**
4. Create coach account: `INSERT INTO auth.users` with `user_metadata: { is_coach: true }` (or use Supabase dashboard Auth → Add User)

**Code changes in jahnrobotics repo:**

| File | Type | Description |
|------|------|-------------|
| `astro.config.mjs` | modify | Add `@astrojs/react`, `@astrojs/vercel`, `output: 'hybrid'` |
| `package.json` | modify | Add dependencies |
| `.env` | new | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` |
| `src/lib/supabase.ts` | new | Server-side Supabase client |
| `src/lib/supabase-browser.ts` | new | Browser-side Supabase client |
| `src/pages/login.astro` | new | Login page (Astro layout + React island) |
| `src/components/auth/LoginForm.tsx` | new | Team name + password form |
| `src/pages/api/auth/login.ts` | new | POST: authenticate, set cookie |
| `src/pages/api/auth/logout.ts` | new | POST: clear cookie |
| `src/pages/api/auth/me.ts` | new | GET: return session info |
| `src/pages/coach/index.astro` | new | Coach dashboard page |
| `src/components/coach/Dashboard.tsx` | new | Team CRUD interface |
| `src/pages/api/teams/create.ts` | new | POST: create team (coach only, uses service role key) |
| `src/pages/api/teams/list.ts` | new | GET: list coach's teams |
| `src/pages/api/teams/delete.ts` | new | DELETE: remove team (coach only) |
| `src/pages/api/teams/reset-password.ts` | new | POST: reset team password (coach only) |

**Vercel env vars to set:**
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

**Verify:** Coach login → create team "Gear Grinders" → team logs in → sees basic landing page → logout works → cookie cleared.

### Phase 2: Pybricks Code Fork + File Save/Load

Add file API endpoints to jahnrobotics. Fork Pybricks Code with jahn-sync.ts.

**jahnrobotics repo additions:**

| File | Type | Description |
|------|------|-------------|
| `src/pages/api/files/save.ts` | new | POST: save file snapshot |
| `src/pages/api/files/load.ts` | new | GET: list/load files |
| `src/pages/api/files/history.ts` | new | GET: version history |
| `src/pages/files.astro` | new | File browser page |
| `src/components/files/FileBrowser.tsx` | new | File list + version timeline |

**Supabase:** Run file_versions table + view + RLS SQL.

**Pybricks Code fork:**
1. Fork `pybricks/pybricks-code` to your GitHub
2. `git remote add upstream https://github.com/pybricks/pybricks-code.git`
3. Add `src/jahn-sync.ts` (reads IndexedDB, injects buttons, calls API)
4. Add `import './jahn-sync'` to `src/index.tsx`
5. Create Vercel project, deploy at `pybricks.jahnrobotics.com`
6. DNS: CNAME `pybricks` → `cname.vercel-dns.com`

**Verify:** Open pybricks.jahnrobotics.com → write code → click "Save to Jahn" → redirected to login → back → save succeeds → go to jahnrobotics.com/files → see the file → save again → see 2 versions.

### Phase 3: XRPWeb Fork

Same pattern. File API already exists.

**XRPWeb fork:**
1. Fork `Open-STEM/XRPWeb` to your GitHub
2. `git remote add upstream https://github.com/Open-STEM/XRPWeb.git`
3. Add `src/jahn-sync.ts` (reads localStorage, injects buttons, calls API)
4. Add `import './jahn-sync'` to `src/main.tsx`
5. Create Vercel project, deploy at `xrp.jahnrobotics.com`
6. DNS: CNAME `xrp` → `cname.vercel-dns.com`

**Verify:** Same flow as Phase 2 but at xrp.jahnrobotics.com.

### Phase 4: Polish
- Navigation links between all apps
- Consistent branding (colors, fonts)
- Coach dashboard: view files from both tools, filter by team
- Test on school Chromebooks
- Optional: manual Pybricks upload fallback at `/pybricks`

---

## DNS Configuration

At your DNS provider for jahnrobotics.com, add:

| Type | Name | Value |
|------|------|-------|
| CNAME | `xrp` | `cname.vercel-dns.com` |
| CNAME | `pybricks` | `cname.vercel-dns.com` |

Then in each Vercel project's Settings → Domains, add the corresponding subdomain. Vercel handles SSL automatically.

---

## Environment Variables

### jahnrobotics.com (Vercel)
```
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=eyJhbGci...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGci...  (only used server-side for coach ops)
```

### xrp.jahnrobotics.com (Vercel)
No special env vars needed — jahn-sync.ts hardcodes the API URL.

### pybricks.jahnrobotics.com (Vercel)
No special env vars needed — jahn-sync.ts hardcodes the API URL.

---

## Verification Checklist

1. [ ] Coach login at /login → redirected to /coach
2. [ ] Coach creates team "Gear Grinders" with password "robot123"
3. [ ] Team login at /login with "Gear Grinders" / "robot123" → redirected to /files
4. [ ] Team sees empty file browser
5. [ ] Open pybricks.jahnrobotics.com → write code → "Save to Jahn" → login redirect → save succeeds
6. [ ] Open xrp.jahnrobotics.com → write code → "Save to Jahn" → login redirect → save succeeds
7. [ ] Go to /files → see saved files from both tools
8. [ ] Save same file again with changes → /files shows 2 snapshots with timestamps
9. [ ] Click older snapshot → view its content → restore it
10. [ ] Coach at /coach → sees "Gear Grinders" → views their files
11. [ ] Different device, same team credentials → sees all the same files
12. [ ] Logout → cookie cleared → subdomain apps show login prompt
13. [ ] `git merge upstream/main` on both forks → clean merges
