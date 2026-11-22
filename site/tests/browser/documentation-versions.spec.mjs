import { test, expect } from '@playwright/test';
import { stableReleaseTag as stableTag } from '../../scripts/stable-release.mjs';

test('switches between versions of the same documentation page', async ({ page }) => {
  await page.goto('/flexr/reference/runtime/');
  const versions = page.getByRole('navigation', { name: 'Documentation version' });
  const main = versions.getByRole('link', { name: 'main', exact: true });
  const stable = versions.getByRole('link', { name: `Stable ${stableTag}`, exact: true });
  await expect(main).toHaveAttribute('aria-current', 'page');
  await stable.click();
  await expect(page).toHaveURL(/\/flexr\/stable\/reference\/runtime\/$/);
  await expect(stable).toHaveAttribute('aria-current', 'page');
  await main.click();
  await expect(page).toHaveURL(/\/flexr\/reference\/runtime\/$/);
});

test('keeps stable documentation links on the released version', async ({ page }) => {
  await page.goto('/flexr/stable/learn/getting-started/');
  await expect(page.getByRole('link', { name: 'calculator tutorial' })).toHaveAttribute(
    'href', `https://github.com/ydah/flexr/blob/${stableTag}/docs/tutorial/build-a-calculator-lexer.md`
  );
  await page.getByRole('link', { name: 'runtime guide' }).click();
  await expect(page).toHaveURL(/\/flexr\/stable\/learn\/runtime-mode\/$/);
});

test('keeps sidebar navigation in the selected version', async ({ page }) => {
  const mainNavigation = page.getByRole('navigation', { name: 'Main', exact: true });
  const gettingStarted = mainNavigation.getByRole('link', { name: 'Getting started', exact: true });
  await page.goto('/flexr/stable/learn/runtime-mode/');
  await expect(gettingStarted).toHaveAttribute('href', '/flexr/stable/learn/getting-started/');
  await page.goto('/flexr/learn/runtime-mode/');
  await expect(gettingStarted).toHaveAttribute('href', '/flexr/learn/getting-started/');
});
