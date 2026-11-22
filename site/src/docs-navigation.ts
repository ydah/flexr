import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { stableReleaseTag } from '../scripts/stable-release.mjs';

export const onRequest = defineRouteMiddleware(({ locals }, next) => {
  const route = locals.starlightRoute;
  const isStable = route.entry.id.startsWith('stable/');
  const prefix = `${import.meta.env.BASE_URL.replace(/\/$/, '')}/stable/`;
  route.sidebar = route.sidebar.filter(item => (item.label === `Stable ${stableReleaseTag}`) === isStable);
  for (const direction of ['prev', 'next'] as const) {
    const link = route.pagination[direction];
    if (link && link.href.startsWith(prefix) !== isStable) route.pagination[direction] = undefined;
  }
  return next();
});
