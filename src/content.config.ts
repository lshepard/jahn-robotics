import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const teams = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/teams' }),
  schema: z.object({
    name: z.string(),
    number: z.number(),
    slug: z.string(),
    season: z.string(),
    seasonYear: z.string(),
    tagline: z.string().optional(),
    color: z.string(),
    awards: z.array(z.object({
      name: z.string(),
      event: z.string(),
    })).optional(),
    advancement: z.string().optional(),
    logo: z.string().optional(),
    photo: z.string().optional(),
    coaches: z.array(z.string()),
    members: z.array(z.object({
      name: z.string(),
      reflection: z.string().optional(),
    })).optional(),
    previousTeam: z.string().optional(),
    nextTeam: z.string().optional(),
  }),
});

const seasons = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/seasons' }),
  schema: z.object({
    name: z.string(),
    slug: z.string(),
    year: z.string(),
    fllTheme: z.string(),
    order: z.number(),
    logo: z.string().optional(),
    background: z.string().optional(),
  }),
});

export const collections = { teams, seasons };
