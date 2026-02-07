import fs from 'node:fs';
import path from 'node:path';

export interface MediaItem {
  src: string;
  type: 'video' | 'photo';
}

const TEAMS_DIR = path.resolve('public/images/teams');
const VIDEO_EXTS = new Set(['.mp4']);
const PHOTO_EXTS = new Set(['.jpg', '.jpeg', '.png']);

function scanTeamDir(slug: string): MediaItem[] {
  const dir = path.join(TEAMS_DIR, slug);
  if (!fs.existsSync(dir)) return [];

  const files = fs.readdirSync(dir);
  const items: MediaItem[] = [];

  for (const file of files) {
    // Only look at converted files (v- prefix for video, p- prefix for photo)
    const ext = path.extname(file).toLowerCase();

    if (file.startsWith('v-') && VIDEO_EXTS.has(ext)) {
      items.push({
        src: `/images/teams/${slug}/${file}`,
        type: 'video',
      });
    } else if (file.startsWith('p-') && PHOTO_EXTS.has(ext)) {
      items.push({
        src: `/images/teams/${slug}/${file}`,
        type: 'photo',
      });
    }
  }

  return items;
}

/** Get media for a specific team by slug */
export function getTeamMedia(slug: string): MediaItem[] {
  return scanTeamDir(slug);
}

/** Get media from all teams (for homepage hero) */
export function getAllMedia(): MediaItem[] {
  if (!fs.existsSync(TEAMS_DIR)) return [];

  const entries = fs.readdirSync(TEAMS_DIR, { withFileTypes: true });
  const all: MediaItem[] = [];

  for (const entry of entries) {
    if (entry.isDirectory()) {
      all.push(...scanTeamDir(entry.name));
    }
  }

  return all;
}

/** Current year's team slugs (UNEARTHED 2025-26) */
const CURRENT_YEAR_TEAMS = [
  'brickbeards',
  'fossilized-chickens',
  'indiana-drones',
  'robo-royals',
];

/** Get media from current year's teams only (for homepage hero) */
export function getCurrentYearMedia(): MediaItem[] {
  const all: MediaItem[] = [];

  for (const slug of CURRENT_YEAR_TEAMS) {
    all.push(...scanTeamDir(slug));
  }

  return all;
}
